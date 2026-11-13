import ApnumCore
import ApnumLinkCore
import Foundation
@testable import ApnumLink

/// An in-process phone: connects over a real WebSocket, runs the Noise initiator and speaks the protocol.
actor FakePhone {
    let keys: KeyPair
    let channel: WebSocketChannel
    private var handshake: Handshake?
    private(set) var session: Session?
    private(set) var handshakeHash = Data()
    private(set) var remoteKey: Data?

    private var inbox: [JSONValue] = []
    private(set) var closed = false
    private(set) var pings = 0
    private var autoPong = true
    private var callHandler: @Sendable (String, JSONValue) async -> Result<JSONValue, ToolError> = { tool, _ in
        .failure(.unavailable("\(tool) is not available in the test"))
    }

    init(port: UInt16, keys: KeyPair) {
        self.keys = keys
        channel = WebSocketChannel.client(host: "127.0.0.1", port: port)
    }

    /// Connects and finishes the handshake. Returns false if the Mac hung up first.
    @discardableResult
    func connect() async throws -> Bool {
        channel.start()
        guard await channel.waitUntilReady() else { return false }
        let hs = try Handshake.initiator(localPrivateKey: keys.privateKey)
        handshake = hs
        Task { await self.readLoop() }
        try await channel.send(try hs.writeMessage())
        let deadline = ContinuousClock.now + .seconds(3)
        while session == nil, !closed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return session != nil
    }

    func setHandler(_ handler: @escaping @Sendable (String, JSONValue) async -> Result<JSONValue, ToolError>) { callHandler = handler }
    func setAutoPong(_ on: Bool) { autoPong = on }

    private func readLoop() async {
        for await data in channel.incoming {
            if session == nil, let hs = handshake {
                do {
                    try hs.readMessage(message: data)
                    try await channel.send(try hs.writeMessage())
                    remoteKey = hs.remotePublicKey()
                    handshakeHash = try hs.handshakeHash()
                    session = try hs.intoSession()
                } catch { break }
                continue
            }
            guard let session, let plain = try? session.open(sealed: data), let message = LinkJSON.decode(plain) else { continue }
            switch LinkJSON.string(message["t"]) {
            case "ping":
                pings += 1
                if autoPong { await send(["t": "pong"]) }
            case "call":
                let id = message["id"] ?? .null
                let tool = LinkJSON.string(message["tool"]) ?? ""
                let input = message["input"] ?? .null
                let handler = callHandler
                Task {
                    switch await handler(tool, input) {
                    case .success(let output): await self.send(["t": "result", "id": id, "ok": true, "output": output])
                    case .failure(let error):
                        let (code, text) = LinkJSON.errorCode(error)
                        await self.send(["t": "result", "id": id, "ok": false, "error": ["code": .string(code), "message": .string(text)]])
                    }
                }
            default:
                inbox.append(message)
            }
        }
        closed = true
    }

    func send(_ message: JSONValue) async {
        guard let session, let sealed = try? session.seal(plaintext: LinkJSON.encode(message)) else { return }
        try? await channel.send(sealed)
    }

    /// The next queued message (calls and pings are handled separately), or nil after the timeout.
    func next(timeout: Duration = .seconds(3)) async -> JSONValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !inbox.isEmpty { return inbox.removeFirst() }
            if closed { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// Skips messages until one with this `t` arrives.
    func expect(_ type: String, timeout: Duration = .seconds(3)) async -> JSONValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let m = await next(timeout: .milliseconds(200)), LinkJSON.string(m["t"]) == type { return m }
            if closed && inbox.isEmpty { return nil }
        }
        return nil
    }

    func waitClosed(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if closed { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return closed
    }

    static func device(name: String = "Pixel Test", id: String = "11111111-1111-1111-1111-111111111111") -> JSONValue {
        ["id": .string(id), "name": .string(name), "kind": "android", "app": "0.1.0", "os": "Android 16"]
    }

    func pair(token: String, name: String = "Pixel Test", timeout: Duration = .seconds(3)) async -> JSONValue? {
        await send(["t": "pair", "token": .string(token), "device": Self.device(name: name)])
        return await expect("paired", timeout: timeout)
    }

    func sendHello(tools: [JSONValue] = FakePhone.defaultTools, name: String = "Pixel Test") async {
        await send(["t": "hello", "v": 1, "device": Self.device(name: name), "tools": .array(tools)])
    }

    static let defaultTools: [JSONValue] = [
        ["name": "phone.info", "summary": "Phone info", "tier": "read", "inputSchema": ["type": "object"]],
        ["name": "phone.sms.send", "summary": "Send an SMS", "tier": "dangerous", "inputSchema": ["type": "object"]],
        ["name": "phone.slow", "summary": "Never answers", "tier": "read", "inputSchema": ["type": "object"]],
    ]

    func close() { channel.close() }
}
