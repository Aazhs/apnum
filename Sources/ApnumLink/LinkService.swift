import ApnumCore
import ApnumLinkCore
import Darwin
import Foundation

enum PairingOutcome: Sendable {
    case paired(PairedDevice)
    case failed(String)
}

/// The phone link, as the rest of the app sees it: pairing, status, calling the phone,
/// and the cached phone state. Everything on the wire follows docs/link-protocol.md.
public actor LinkService {
    public static let defaultPort: UInt16 = 47800
    /// ChangeFeed topics the phone is told about.
    private static let forwardedTopics: Set<String> = ["alarms", "timers", "notes", "calendar", "reminders", "sky", "ringing"]

    private let paths: AppPaths
    private let changes: ChangeFeed
    private let keys: any KeyStoring
    private let bonjour: Bool
    private let requestedPort: UInt16
    private let timing: LinkTiming
    private let pairingLifetime: TimeInterval
    private let store: LinkStore
    private let server = LinkServer()

    private var identity: LinkIdentity?
    private var registry: ToolRegistry?
    private var running = false
    private var port: UInt16?
    private var feedTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?

    private struct Offer {
        var token: Data
        var expiresAt: Date
        var attempts = 0
    }
    private var offer: Offer?
    private var safetyNumber: String?

    private var current: LinkSession?
    private var connectedSince: Date?
    private var phone = PhoneState()
    private var onCode: (@Sendable (PhoneCode) async -> Void)?

    /// - Parameters:
    ///   - port: 0 picks any free port (tests).
    ///   - bonjour: false skips advertising (tests).
    public init(
        paths: AppPaths, changes: ChangeFeed, keys: any KeyStoring, bonjour: Bool = true, port: UInt16 = LinkService.defaultPort,
        callTimeout: Duration = .seconds(30), pingInterval: Duration = .seconds(20), silenceTimeout: Duration = .seconds(45),
        pairingLifetime: TimeInterval = 300
    ) {
        self.paths = paths
        self.changes = changes
        self.keys = keys
        self.bonjour = bonjour
        self.requestedPort = port
        self.timing = LinkTiming(callTimeout: callTimeout, pingInterval: pingInterval, silenceTimeout: silenceTimeout)
        self.pairingLifetime = pairingLifetime
        self.store = LinkStore(paths: paths)
    }

    // MARK: Setup

    /// Lets the link run Mac tools for the phone and add the phone's tools.
    public func attach(registry: ToolRegistry) { self.registry = registry }

    /// Called with each one-time code the phone reports.
    public func setOnCode(_ hook: (@Sendable (PhoneCode) async -> Void)?) { onCode = hook }

    public func load() async throws {
        try await store.load()
        identity = try LinkIdentity.load(keys: keys, deviceID: await store.file.deviceID)
    }

    /// Starts listening (if enabled) and forwarding changes to the phone.
    public func start() async throws {
        guard !running, await store.file.settings.enabled else { return }
        if identity == nil { try await load() }
        guard let identity else { return }
        let txt = ["v": "1", "id": identity.deviceID.uuidString.lowercased()]
        let actual = try await server.start(
            port: requestedPort, bonjourName: bonjour ? identity.name : nil, txt: txt,
            onConnection: { [weak self] channel in
                guard let self else { return channel.close() }
                Task { await self.accept(channel) }
            })
        port = actual
        running = true
        feedTask = Task { [weak self, changes] in
            for await topic in changes.subscribe() {
                await self?.forward(topic)
            }
        }
        changes.publish(.link)
    }

    public func stop() async {
        guard running else { return }
        running = false
        server.stop()
        feedTask?.cancel()
        feedTask = nil
        offer = nil
        safetyNumber = nil
        port = nil
        if let current { await current.close(reason: "closing") }
        changes.publish(.link)
    }

    private func accept(_ channel: WebSocketChannel) async {
        guard running, let identity else { return channel.close() }
        let session = LinkSession(channel: channel, service: self, privateKey: identity.privateKey, timing: timing)
        await session.run()
    }

    // MARK: Status and settings

    public func status() async -> LinkStatus {
        let file = await store.file
        guard file.settings.enabled else { return .off }
        guard let device = file.device else { return .notPaired }
        if current != nil, let connectedSince { return .connected(device: device, since: connectedSince) }
        return .waitingForPhone
    }

    public func settings() async -> LinkSettings { await store.file.settings }
    public func pairedDevice() async -> PairedDevice? { await store.file.device }
    public func listeningPort() -> UInt16? { port }
    public func fingerprint() -> String? { identity?.fingerprint }
    public func phoneState() -> PhoneState { phone }
    public func macDeviceName() -> String? { identity?.name }

    public func setEnabled(_ enabled: Bool) async throws {
        try await store.update { $0.settings.enabled = enabled }
        if enabled { try await start() } else { await stop() }
        changes.publish(.link)
    }

    public func setAutoCopyCodes(_ on: Bool) async throws {
        try await store.update { $0.settings.autoCopyCodes = on }
        changes.publish(.link)
    }

    public func setTrustDangerous(_ on: Bool) async throws {
        guard await store.file.device != nil else { throw ToolError.unavailable("No phone is paired.") }
        try await store.update { $0.device?.trustDangerous = on }
        changes.publish(.link)
    }

    /// For `DefaultPermissionPolicy(trusted:)`: true when the caller is the paired phone and the user allowed dangerous actions.
    public func isTrusted(caller: Caller) async -> Bool {
        guard case .phone(let name) = caller, let device = await store.file.device else { return false }
        return device.trustDangerous && device.name == name
    }

    // MARK: Pairing

    public func beginPairing() async throws -> PairingOffer {
        guard let identity, running, let port else { throw ToolError.unavailable("The phone link is turned off.") }
        let token = try pairingToken()
        let expires = Date().addingTimeInterval(pairingLifetime)
        offer = Offer(token: token, expiresAt: expires)
        safetyNumber = nil
        let host = Self.primaryIPv4() ?? "127.0.0.1"
        let uri = makePairUri(host: host, port: port, publicKey: identity.publicKey, token: token, name: identity.name)
        changes.publish(.link)
        return PairingOffer(
            uri: uri, code: pairingCode(token: token), expiresAt: expires, fingerprint: identity.fingerprint, host: host, port: port)
    }

    public func cancelPairing() {
        offer = nil
        safetyNumber = nil
        changes.publish(.link)
    }

    /// The 6-digit number both screens show when the phone paired by typing the code.
    public func pairingSafetyNumber() -> String? { safetyNumber }

    public func unpair() async throws {
        guard await store.file.device != nil else { return }
        try await store.update { $0.device = nil }
        offer = nil
        safetyNumber = nil
        if let current { await current.close(reason: "unpair") }
        changes.publish(.link)
    }

    private var offerIsActive: Bool { offer.map { $0.expiresAt > Date() } ?? false }

    func authenticate(remoteKey: Data, handshakeHash: Data) async -> AuthDecision {
        if let device = await store.file.device, device.publicKeyData == remoteKey { return .known(device) }
        guard offerIsActive else { return .refuse }
        safetyNumber = ApnumLinkCore.safetyNumber(handshakeHash: handshakeHash)
        changes.publish(.link)
        return .pairing
    }

    func completePairing(token: String, device: JSONValue, remoteKey: Data) async -> PairingOutcome {
        guard var pending = offer else { return .failed("No pairing is in progress.") }
        guard pending.expiresAt > Date() else {
            offer = nil
            safetyNumber = nil
            changes.publish(.link)
            return .failed("The pairing code expired.")
        }
        let given = token.filter { !$0.isWhitespace && $0 != "=" }
        guard given == Self.base64URL(pending.token) || given == pairingCode(token: pending.token) else {
            pending.attempts += 1
            if pending.attempts >= 5 { offer = nil; safetyNumber = nil } else { offer = pending }
            changes.publish(.link)
            return .failed("That code is not right.")
        }
        let old = await store.file.device
        let id = LinkJSON.string(device["id"]) ?? UUID().uuidString
        let paired = PairedDevice(
            id: id, name: LinkJSON.string(device["name"]) ?? "Phone", kind: LinkJSON.string(device["kind"]) ?? "android",
            os: LinkJSON.string(device["os"]), app: LinkJSON.string(device["app"]), publicKey: remoteKey.base64EncodedString(),
            pairedAt: Date(), lastSeen: Date(), trustDangerous: old?.id == id ? old?.trustDangerous ?? false : false)
        do { try await store.update { $0.device = paired } } catch { return .failed("Could not save the pairing.") }
        offer = nil
        safetyNumber = nil
        changes.publish(.link)
        return .paired(paired)
    }

    // MARK: Session callbacks

    func sessionAuthenticated(_ session: LinkSession, device: PairedDevice) async {
        let old = current
        current = session
        connectedSince = Date()
        phone = PhoneState()
        try? await store.update { $0.device?.lastSeen = Date() }
        if let old, old.id != session.id { await old.close(reason: "replaced") }
        changes.publish(.link)
        changes.publish(.phone)
    }

    func sessionEnded(_ session: LinkSession) async {
        if current?.id == session.id {
            current = nil
            connectedSince = nil
            infoTask?.cancel()
            registry?.removeRemoteTools(source: "phone")
            phone = PhoneState()
            try? await store.update { $0.device?.lastSeen = Date() }
            changes.publish(.phone)
        }
        if !(await session.authenticated) { safetyNumber = nil }
        changes.publish(.link)
    }

    func peerUnpaired(_ session: LinkSession) async {
        guard current?.id == session.id else { return }
        try? await store.update { $0.device = nil }
    }

    func peerHello(_ session: LinkSession, message: JSONValue) async {
        guard current?.id == session.id else { return }
        if let device = message["device"] {
            try? await store.update {
                if let name = LinkJSON.string(device["name"]) { $0.device?.name = name }
                if let os = LinkJSON.string(device["os"]) { $0.device?.os = os }
                if let app = LinkJSON.string(device["app"]) { $0.device?.app = app }
            }
        }
        await peerTools(session, message: message)
        infoTask?.cancel()
        infoTask = Task { [weak self] in await self?.refreshPhone() }
        changes.publish(.link)
    }

    func peerTools(_ session: LinkSession, message: JSONValue) async {
        guard current?.id == session.id, case .array(let list)? = message["tools"] else { return }
        let descriptors = list.compactMap { try? $0.decode(ToolDescriptor.self) }.filter { $0.name.hasPrefix("phone.") }
        registry?.setRemoteTools(source: "phone", descriptors: descriptors) { [weak self] tool, input, _ in
            guard let self else { throw ToolError.unavailable("The phone link is not running.") }
            return try await self.callPhone(tool: tool, input: input)
        }
        changes.publish(.phone)
    }

    func helloMessage() async -> JSONValue {
        let tools = (try? JSONValue(encoding: registry?.localDescriptors ?? [])) ?? .array([])
        return ["t": "hello", "v": 1, "device": deviceJSON(), "tools": tools]
    }

    func deviceJSON() -> JSONValue {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return [
            "id": .string((identity?.deviceID ?? UUID()).uuidString.lowercased()), "name": .string(identity?.name ?? "Mac"),
            "kind": "mac", "app": .string(app), "os": .string("macOS \(v.majorVersion).\(v.minorVersion)"),
        ]
    }

    func runMacTool(_ tool: String, input: JSONValue, deviceName: String) async throws -> JSONValue {
        guard let registry, !tool.hasPrefix("phone.") else { throw ToolError.notFound(tool) }
        return try await registry.callJSON(tool, input: input, caller: .phone(deviceName))
    }

    private func forward(_ topic: ChangeTopic) async {
        guard Self.forwardedTopics.contains(topic.rawValue), let current else { return }
        await current.send(["t": "event", "topic": "changed", "data": ["topic": .string(topic.rawValue)]])
    }

    // MARK: Calling the phone

    /// Calls a tool on the connected phone, bypassing the registry (the registry forwards here).
    public func callPhone(tool: String, input: JSONValue = .null) async throws -> JSONValue {
        guard let current else { throw ToolError.unavailable("No phone is connected.") }
        return try await current.call(tool: tool, input: input == .null ? .object([:]) : input)
    }

    /// Fetches battery, recent messages, notifications and call state from the phone again.
    public func refreshPhone() async {
        func fetch(_ tool: String, _ input: JSONValue = .object([:])) async -> JSONValue? {
            try? await callPhone(tool: tool, input: input)
        }
        if let info = await fetch("phone.info") {
            phone.info = info
            if let percent = Self.firstNumber(info, ["batteryPercent", "battery", "percent", "batteryLevel"]) { phone.battery = Int(percent) }
            if let charging = Self.firstBool(info, ["charging", "isCharging"]) { phone.charging = charging }
            changes.publish(.phone)
        }
        if let list = await fetch("phone.sms.list", ["limit": 50]) {
            phone.messages = Array(Self.items(list).compactMap { Self.parseSMS($0) }.sorted { $0.date > $1.date }.prefix(50))
            changes.publish(.phone)
        }
        if let list = await fetch("phone.notifications.list") {
            phone.notifications = Self.items(list).compactMap(Self.parseNotification)
            changes.publish(.phone)
        }
        if let state = await fetch("phone.call.state") {
            phone.call = Self.parseCall(state)
            changes.publish(.phone)
        }
    }

    // MARK: Events from the phone

    func peerEvent(topic: String, data: JSONValue) async {
        switch topic {
        case "sms.received":
            guard let sms = Self.parseSMS(data, incoming: true) else { return }
            phone.messages.removeAll { $0.id == sms.id }
            phone.messages.insert(sms, at: 0)
            if phone.messages.count > 50 { phone.messages.removeLast(phone.messages.count - 50) }
            var code: PhoneCode?
            if let otp = LinkJSON.string(data["otp"]) ?? LinkJSON.number(data["otp"]).map({ String(Int($0)) }), !otp.isEmpty {
                code = PhoneCode(code: otp, from: sms.title, date: sms.date)
                phone.latestCode = code
            }
            changes.publish(.phone)
            if let code, let onCode { Task { await onCode(code) } }
        case "notification.posted":
            guard let n = Self.parseNotification(data) else { return }
            phone.notifications.removeAll { $0.key == n.key }
            phone.notifications.insert(n, at: 0)
            changes.publish(.phone)
        case "notification.removed":
            guard let key = LinkJSON.string(data["key"]) else { return }
            phone.notifications.removeAll { $0.key == key }
            changes.publish(.phone)
        case "call.state":
            phone.call = Self.parseCall(data)
            changes.publish(.phone)
        case "battery":
            if let p = LinkJSON.number(data["percent"]) { phone.battery = Int(p) }
            if let c = LinkJSON.bool(data["charging"]) { phone.charging = c }
            changes.publish(.phone)
        default:
            break
        }
    }

    // MARK: Parsing helpers

    /// Reads the output of `phone.sms.list` (an array, or an object holding one), newest first.
    public static func parseMessages(_ value: JSONValue) -> [PhoneSMS] {
        items(value).compactMap { parseSMS($0) }.sorted { $0.date > $1.date }
    }

    static func items(_ value: JSONValue) -> [JSONValue] {
        if case .array(let a) = value { return a }
        if case .object(let o) = value {
            for key in o.keys.sorted() { if case .array(let a) = o[key]! { return a } }
        }
        return []
    }

    static func firstNumber(_ value: JSONValue, _ keys: [String]) -> Double? {
        for key in keys { if let n = LinkJSON.number(value[key]) { return n } }
        return nil
    }

    static func firstBool(_ value: JSONValue, _ keys: [String]) -> Bool? {
        for key in keys { if let b = LinkJSON.bool(value[key]) { return b } }
        return nil
    }

    static func parseSMS(_ v: JSONValue, incoming: Bool = true) -> PhoneSMS? {
        guard let address = LinkJSON.string(v["address"]), let body = LinkJSON.string(v["body"]) else { return nil }
        let date = LinkJSON.date(ms: v["dateMs"]) ?? Date()
        let rawID = LinkJSON.string(v["id"]) ?? LinkJSON.number(v["id"]).map { String(Int($0)) }
        return PhoneSMS(
            id: rawID ?? "\(Int(date.timeIntervalSince1970 * 1000))-\(address)", address: address,
            contactName: LinkJSON.string(v["contactName"]), body: body, date: date,
            incoming: LinkJSON.bool(v["incoming"]) ?? incoming)
    }

    static func parseNotification(_ v: JSONValue) -> PhoneNotification? {
        guard let key = LinkJSON.string(v["key"]) else { return nil }
        return PhoneNotification(
            key: key, app: LinkJSON.string(v["app"]) ?? "", title: LinkJSON.string(v["title"]) ?? "",
            text: LinkJSON.string(v["text"]) ?? "", posted: LinkJSON.date(ms: v["postedMs"]) ?? Date())
    }

    static func parseCall(_ v: JSONValue) -> PhoneCall {
        PhoneCall(
            state: LinkJSON.string(v["state"]) ?? "idle", number: LinkJSON.string(v["number"]),
            contactName: LinkJSON.string(v["contactName"]))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// This Mac's address on the active network: en0 first, then any other up interface, never loopback.
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = ptr.pointee
            guard let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if address.hasPrefix("169.254.") { continue }
            candidates.append((String(cString: item.ifa_name), address))
        }
        return candidates.first { $0.name == "en0" }?.address
            ?? candidates.first { $0.name.hasPrefix("en") }?.address
            ?? candidates.first?.address
    }
}
