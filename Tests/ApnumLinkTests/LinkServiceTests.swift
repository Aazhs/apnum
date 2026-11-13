import ApnumCore
import ApnumLinkCore
import Foundation
import Testing
@testable import ApnumLink

struct EchoTool: Tool {
    struct Input: Decodable, Sendable { var text: String }
    struct Output: Encodable, Sendable { var text: String }
    static let name = "test.echo"
    static let summary = "Echo the text back."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.object(["text": .string()], required: ["text"])
    func run(_ input: Input, context: ToolContext) async throws -> Output { Output(text: input.text) }
}

struct DangerTool: Tool {
    static let name = "test.danger"
    static let summary = "A dangerous action."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Ack { Ack() }
}

struct Harness: Sendable {
    let link: LinkService
    let registry: ToolRegistry
    let audit: AuditLog
    let changes = ChangeFeed()
    let port: UInt16
    let paths: AppPaths

    init(
        callTimeout: Duration = .seconds(5), pingInterval: Duration = .seconds(20), silenceTimeout: Duration = .seconds(45),
        pairingLifetime: TimeInterval = 300, paths: AppPaths = .temporary()
    ) async throws {
        self.paths = paths
        let link = LinkService(
            paths: paths, changes: changes, keys: FileKeyStore(paths: paths), bonjour: false, port: 0,
            callTimeout: callTimeout, pingInterval: pingInterval, silenceTimeout: silenceTimeout, pairingLifetime: pairingLifetime)
        let audit = AuditLog(url: nil)
        registry = ToolRegistry(
            tools: [AnyTool(EchoTool()), AnyTool(DangerTool())] + link.makeTools(),
            policy: DefaultPermissionPolicy(trusted: { caller in await link.isTrusted(caller: caller) }), audit: audit)
        await link.attach(registry: registry)
        try await link.load()
        try await link.start()
        self.link = link
        self.audit = audit
        port = try #require(await link.listeningPort())
    }

    /// Pairs a fresh fake phone and completes the hello exchange.
    func pair(useCode: Bool = false, name: String = "Pixel Test", keys: KeyPair? = nil) async throws -> FakePhone {
        let offer = try await link.beginPairing()
        let info = try parsePairUri(uri: offer.uri)
        let phone = FakePhone(port: port, keys: try keys ?? generateKeypair())
        #expect(try await phone.connect())
        let paired = await phone.pair(token: useCode ? offer.code : LinkService.base64URL(info.token), name: name)
        #expect(paired?["ok"] == true)
        _ = await phone.expect("hello")
        await phone.sendHello(name: name)
        await eventually { registry.descriptors.contains { $0.name == "phone.info" } }
        return phone
    }
}

func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func isConnected(_ link: LinkService) async -> Bool {
    if case .connected = await link.status() { return true } else { return false }
}

@Suite struct LinkServiceTests {
    @Test func pairsWithTheTokenAndListsMacTools() async throws {
        let h = try await Harness()
        #expect(await h.link.status() == .notPaired)
        let offer = try await h.link.beginPairing()
        let info = try parsePairUri(uri: offer.uri)
        #expect(info.port == h.port)
        #expect(!info.host.isEmpty && info.host != "0.0.0.0")
        #expect(offer.code == pairingCode(token: info.token))
        #expect(offer.fingerprint == (await h.link.fingerprint()))

        let phone = FakePhone(port: h.port, keys: try generateKeypair())
        #expect(try await phone.connect())
        #expect(await phone.remoteKey == info.publicKey)  // the QR path check the phone does
        let paired = try #require(await phone.pair(token: LinkService.base64URL(info.token)))
        #expect(paired["ok"] == true)
        #expect(paired["device"]?["kind"] == "mac")
        let hello = try #require(await phone.expect("hello"))
        var names = Set<String>()
        if case .array(let list)? = hello["tools"] { names = Set(list.compactMap { LinkJSON.string($0["name"]) }) }
        #expect(names.isSuperset(of: ["test.echo", "test.danger", "link.status"]))
        #expect(hello["v"] == 1)

        let device = try #require(await h.link.pairedDevice())
        #expect(device.name == "Pixel Test" && device.kind == "android" && device.trustDangerous == false)
        #expect(device.publicKeyData == phone.keys.publicKey)
        await eventually { await isConnected(h.link) }
        #expect(await isConnected(h.link))
        // The offer is single use.
        let second = FakePhone(port: h.port, keys: try generateKeypair())
        #expect(try await second.connect())
        #expect(await second.waitClosed())
    }

    @Test func pairsWithTheEightDigitCodeAndSharesASafetyNumber() async throws {
        let h = try await Harness()
        let offer = try await h.link.beginPairing()
        let phone = FakePhone(port: h.port, keys: try generateKeypair())
        #expect(try await phone.connect())
        await eventually { await h.link.pairingSafetyNumber() != nil }
        let number = try #require(await h.link.pairingSafetyNumber())
        #expect(number.count == 6)
        #expect(number == safetyNumber(handshakeHash: await phone.handshakeHash))
        let paired = await phone.pair(token: offer.code)
        #expect(paired?["ok"] == true)
        #expect(await h.link.pairingSafetyNumber() == nil)
    }

    @Test func wrongTokenIsRejectedAndFiveFailuresCancelPairing() async throws {
        let h = try await Harness()
        let offer = try await h.link.beginPairing()
        let info = try parsePairUri(uri: offer.uri)
        for _ in 0..<5 {
            let phone = FakePhone(port: h.port, keys: try generateKeypair())
            #expect(try await phone.connect())
            let reply = try #require(await phone.pair(token: "00000000"))
            #expect(reply["ok"] == false)
            #expect(await phone.waitClosed())
        }
        // The right token no longer works: the pairing session is gone.
        let late = FakePhone(port: h.port, keys: try generateKeypair())
        #expect(try await late.connect())
        let reply = await late.pair(token: LinkService.base64URL(info.token), timeout: .seconds(1))
        #expect(reply == nil || reply?["ok"] == false)
        #expect(await late.waitClosed())
        #expect(await h.link.pairedDevice() == nil)
    }

    @Test func expiredOfferIsRefused() async throws {
        let h = try await Harness(pairingLifetime: -1)
        let offer = try await h.link.beginPairing()
        let info = try parsePairUri(uri: offer.uri)
        let phone = FakePhone(port: h.port, keys: try generateKeypair())
        #expect(try await phone.connect())
        let reply = await phone.pair(token: LinkService.base64URL(info.token), timeout: .seconds(1))
        #expect(reply == nil || reply?["ok"] == false)
        #expect(await phone.waitClosed())
        #expect(await h.link.pairedDevice() == nil)
    }

    @Test func reconnectsWithTheStoredKeyAndRefusesUnknownKeys() async throws {
        let h = try await Harness()
        let keys = try generateKeypair()
        let first = try await h.pair(keys: keys)
        await first.close()
        await eventually { !(await isConnected(h.link)) }
        #expect(!(await isConnected(h.link)))
        #expect(registryHasNoPhoneTools(h.registry))

        let again = FakePhone(port: h.port, keys: keys)
        #expect(try await again.connect())
        #expect(await again.expect("hello") != nil)  // no pairing needed
        await eventually { await isConnected(h.link) }
        #expect(await isConnected(h.link))

        let stranger = FakePhone(port: h.port, keys: try generateKeypair())
        #expect(try await stranger.connect())
        #expect(await stranger.waitClosed())
        #expect(await stranger.expect("hello", timeout: .milliseconds(200)) == nil)
        #expect(await isConnected(h.link))  // the real phone is untouched
    }

    @Test func aNewConnectionReplacesTheOldOne() async throws {
        let h = try await Harness()
        let keys = try generateKeypair()
        let first = try await h.pair(keys: keys)
        let second = FakePhone(port: h.port, keys: keys)
        #expect(try await second.connect())
        #expect(await second.expect("hello") != nil)
        let bye = await first.expect("bye")
        #expect(bye != nil)
        #expect(await first.waitClosed())
        await second.sendHello()
        #expect(await isConnected(h.link))
    }

    @Test func phoneCallsRunAsThePhoneCallerAndAreAudited() async throws {
        let h = try await Harness()
        let phone = try await h.pair()
        await phone.send(["t": "call", "id": 7, "tool": "test.echo", "input": ["text": "hi"]])
        let result = try #require(await phone.expect("result"))
        #expect(result["id"] == 7 && result["ok"] == true && result["output"]?["text"] == "hi")
        let entries = await h.audit.recent()
        let entry = try #require(entries.first { $0.tool == "test.echo" })
        #expect(entry.caller == "phone:Pixel Test" && entry.outcome == .ok)

        await phone.send(["t": "call", "id": 8, "tool": "nope.nothing", "input": [:]])
        let missing = try #require(await phone.expect("result"))
        #expect(missing["ok"] == false && missing["error"]?["code"] == "notFound")
        // The phone cannot call its own tools back through the Mac.
        await phone.send(["t": "call", "id": 9, "tool": "phone.info", "input": [:]])
        let own = try #require(await phone.expect("result"))
        #expect(own["error"]?["code"] == "notFound")
    }

    @Test func dangerousMacToolsAreDeniedUntilTrusted() async throws {
        let h = try await Harness()
        let phone = try await h.pair()
        await phone.send(["t": "call", "id": 1, "tool": "test.danger", "input": [:]])
        let denied = try #require(await phone.expect("result"))
        #expect(denied["ok"] == false && denied["error"]?["code"] == "denied")
        #expect(await h.audit.recent().first { $0.tool == "test.danger" }?.outcome == .denied)

        try await h.link.setTrustDangerous(true)
        await phone.send(["t": "call", "id": 2, "tool": "test.danger", "input": [:]])
        let allowed = try #require(await phone.expect("result"))
        #expect(allowed["ok"] == true)
        // An agent is never trusted through the phone's setting.
        #expect(await h.link.isTrusted(caller: .agent("claude")) == false)
        #expect(await h.link.isTrusted(caller: .phone("Pixel Test")))
        #expect(await h.link.isTrusted(caller: .phone("Other")) == false)
    }

    @Test func macCallsThePhoneAndMapsErrors() async throws {
        let h = try await Harness()
        let phone = try await h.pair()
        await phone.setHandler { tool, input in
            switch tool {
            case "phone.info": .success(["model": "Pixel", "battery": 80])
            case "phone.sms.send": .failure(.unavailable("SMS permission is not granted"))
            default: .failure(.unavailable("nope"))
            }
        }
        let info = try await h.link.callPhone(tool: "phone.info")
        #expect(info["model"] == "Pixel")
        // Through the registry, as the UI would.
        let viaRegistry = try await h.registry.callJSON("phone.info", caller: .ui)
        #expect(viaRegistry["battery"] == 80)
        await #expect(throws: ToolError.unavailable("SMS permission is not granted")) {
            _ = try await h.registry.callJSON("phone.sms.send", input: ["to": "1", "body": "x"], caller: .ui)
        }
        // The phone's dangerous tool is subject to the same policy for agents.
        await #expect(throws: ToolError.self) {
            _ = try await h.registry.callJSON("phone.sms.send", input: [:], caller: .agent("claude"))
        }
    }

    @Test func callsTimeOut() async throws {
        let h = try await Harness(callTimeout: .milliseconds(300))
        let phone = try await h.pair()
        await phone.setHandler { tool, _ in
            try? await Task.sleep(for: .seconds(30))
            return .success(.null)
        }
        let started = ContinuousClock.now
        await #expect(throws: ToolError.self) { _ = try await h.link.callPhone(tool: "phone.slow") }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func remoteToolsAppearAndVanish() async throws {
        let h = try await Harness()
        #expect(!(h.registry.descriptors.contains { $0.name == "phone.info" }))
        let phone = try await h.pair()
        let names = h.registry.descriptors.map(\.name)
        #expect(names.contains("phone.info") && names.contains("phone.sms.send"))
        await phone.close()
        await eventually { registryHasNoPhoneTools(h.registry) }
        #expect(registryHasNoPhoneTools(h.registry))
        await #expect(throws: ToolError.self) { _ = try await h.link.callPhone(tool: "phone.info") }
    }

    @Test func eventsUpdateStateAndTriggerTheCodeHook() async throws {
        let h = try await Harness()
        let codes = LockedBox<[PhoneCode]>([])
        await h.link.setOnCode { codes.set(codes.get() + [$0]) }
        let phone = try await h.pair()
        await phone.send(["t": "event", "topic": "battery", "data": ["percent": 55, "charging": true]])
        await phone.send(["t": "event", "topic": "notification.posted", "data": ["key": "k1", "app": "Mail", "title": "Hi", "text": "Body", "postedMs": 1_700_000_000_000]])
        await phone.send(["t": "event", "topic": "call.state", "data": ["state": "ringing", "number": "+911234"]])
        await phone.send([
            "t": "event", "topic": "sms.received",
            "data": ["address": "HDFCBK", "body": "Your code is 482913", "dateMs": 1_700_000_100_000, "otp": "482913"],
        ])
        await eventually { codes.get().count == 1 }
        let state = await h.link.phoneState()
        #expect(state.battery == 55 && state.charging == true)
        #expect(state.notifications.map(\.key) == ["k1"])
        #expect(state.call.state == "ringing" && state.call.number == "+911234")
        #expect(state.messages.first?.address == "HDFCBK")
        #expect(state.latestCode?.code == "482913" && state.latestCode?.from == "HDFCBK")
        #expect(codes.get().first?.code == "482913")

        await phone.send(["t": "event", "topic": "notification.removed", "data": ["key": "k1"]])
        await eventually { await h.link.phoneState().notifications.isEmpty }
        #expect(await h.link.phoneState().notifications.isEmpty)
    }

    @Test func aLargeSealedMessageSurvives() async throws {
        let h = try await Harness()
        let phone = try await h.pair()
        let big = String(repeating: "x", count: 300_000)
        await phone.send(["t": "call", "id": 1, "tool": "test.echo", "input": ["text": .string(big)]])
        let result = try #require(await phone.expect("result", timeout: .seconds(5)))
        #expect(LinkJSON.string(result["output"]?["text"])?.count == 300_000)
    }

    @Test func unpairSendsByeAndRefusesTheNextConnection() async throws {
        let h = try await Harness()
        let keys = try generateKeypair()
        let phone = try await h.pair(keys: keys)
        try await h.link.unpair()
        let bye = try #require(await phone.expect("bye"))
        #expect(bye["reason"] == "unpair")
        #expect(await phone.waitClosed())
        #expect(await h.link.status() == .notPaired)
        #expect(await h.link.pairedDevice() == nil)
        #expect(registryHasNoPhoneTools(h.registry))
        let again = FakePhone(port: h.port, keys: keys)
        #expect(try await again.connect())
        #expect(await again.waitClosed())
        #expect(await again.expect("hello", timeout: .milliseconds(200)) == nil)
    }

    @Test func pingsAndDropsASilentPhone() async throws {
        let h = try await Harness(pingInterval: .milliseconds(100), silenceTimeout: .milliseconds(500))
        let phone = try await h.pair()
        await phone.setAutoPong(false)
        #expect(await phone.waitClosed(timeout: .seconds(3)))
        #expect(await phone.pings >= 1)
        await eventually { !(await isConnected(h.link)) }
        #expect(!(await isConnected(h.link)))
    }

    @Test func toolsReportStatusAndSettings() async throws {
        let h = try await Harness()
        let off = try await h.registry.callJSON("link.status", caller: .ui)
        #expect(off["status"] == "notPaired")
        let begin = try await h.registry.callJSON("link.pair.begin", caller: .ui)
        #expect(begin["code"].flatMap(LinkJSON.string)?.count == 8)
        // Agents cannot start pairing (dangerous) or widen the phone's permissions.
        await #expect(throws: ToolError.self) { _ = try await h.registry.callJSON("link.pair.begin", caller: .agent("x")) }
        _ = try await h.registry.callJSON("link.pair.cancel", caller: .ui)
        _ = try await h.registry.callJSON("link.settings.set", input: ["autoCopyCodes": false], caller: .ui)
        #expect(await h.link.settings().autoCopyCodes == false)
        _ = try await h.registry.callJSON("link.settings.set", input: ["enabled": false], caller: .ui)
        #expect(await h.link.status() == .off)
        #expect(await h.link.listeningPort() == nil)
    }
}

func registryHasNoPhoneTools(_ registry: ToolRegistry) -> Bool {
    !registry.descriptors.contains { $0.name.hasPrefix("phone.") }
}
