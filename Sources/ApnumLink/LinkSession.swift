import ApnumCore
import ApnumLinkCore
import Foundation

/// How long a session waits and how often it pings. Injectable so tests stay fast.
struct LinkTiming: Sendable {
    var callTimeout: Duration = .seconds(30)
    var pingInterval: Duration = .seconds(20)
    var silenceTimeout: Duration = .seconds(45)
}

enum AuthDecision: Sendable {
    case known(PairedDevice)
    case pairing
    case refuse
}

/// One phone connection on the Mac: the Noise XX handshake (as responder), then sealed JSON messages.
/// Policy (who may connect, what a call may do) lives in `LinkService`; this type speaks the protocol.
actor LinkSession {
    let id = UUID()
    private let channel: WebSocketChannel
    private unowned let service: LinkService
    private let privateKey: Data
    private let timing: LinkTiming

    private var noise: Session?
    private(set) var authenticated = false
    private(set) var deviceName = "phone"
    private var closed = false

    private struct Pending { let continuation: CheckedContinuation<JSONValue, any Error> }
    private var pending: [Int: Pending] = [:]
    private var nextCallID = 1
    private var lastReceived = ContinuousClock.now
    private var lastSent = ContinuousClock.now
    private var heartbeat: Task<Void, Never>?

    init(channel: WebSocketChannel, service: LinkService, privateKey: Data, timing: LinkTiming) {
        self.channel = channel
        self.service = service
        self.privateKey = privateKey
        self.timing = timing
    }

    // MARK: Lifecycle

    func run() async {
        defer { channel.close() }
        var iterator = channel.incoming.makeAsyncIterator()
        var remoteKey = Data()
        do {
            let handshake = try Handshake.responder(localPrivateKey: privateKey)
            guard let first = await iterator.next() else { return await finish() }
            try handshake.readMessage(message: first)
            try await channel.send(try handshake.writeMessage())
            guard let third = await iterator.next() else { return await finish() }
            try handshake.readMessage(message: third)
            guard handshake.isFinished(), let key = handshake.remotePublicKey() else { return await finish() }
            remoteKey = key
            let hash = try handshake.handshakeHash()
            noise = try handshake.intoSession()

            switch await service.authenticate(remoteKey: remoteKey, handshakeHash: hash) {
            case .known(let device):
                try await accept(device)
            case .pairing:
                break
            case .refuse:
                await send(["t": "bye", "reason": "unknown device"])
                return await finish()
            }
        } catch {
            return await finish()
        }

        lastReceived = .now
        heartbeat = Task { [weak self] in await self?.heartbeatLoop() }
        while let data = await iterator.next() {
            guard let noise, let plain = try? noise.open(sealed: data), let message = LinkJSON.decode(plain) else {
                break  // tampered or malformed: drop the link
            }
            lastReceived = .now
            if closed { break }
            await handle(message, remoteKey: remoteKey)
            if closed { break }
        }
        await finish()
    }

    private func finish() async {
        heartbeat?.cancel()
        closed = true
        let waiting = pending
        pending = [:]
        for (_, entry) in waiting { entry.continuation.resume(throwing: ToolError.unavailable("The phone disconnected.")) }
        await service.sessionEnded(self)
    }

    /// Sends `bye` (when asked) and closes the connection. Safe to call more than once.
    func close(reason: String?) async {
        guard !closed else { return }
        if let reason { await send(["t": "bye", "reason": .string(reason)]) }
        closed = true
        heartbeat?.cancel()
        channel.close()
    }

    private func accept(_ device: PairedDevice) async throws {
        authenticated = true
        deviceName = device.name
        await service.sessionAuthenticated(self, device: device)
        await send(await service.helloMessage())
    }

    // MARK: Messages

    private func handle(_ message: JSONValue, remoteKey: Data) async {
        guard let type = LinkJSON.string(message["t"]) else { return }
        if type == "pair" {
            await handlePair(message, remoteKey: remoteKey)
            return
        }
        guard authenticated else { return }
        switch type {
        case "hello":
            await service.peerHello(self, message: message)
        case "tools":
            await service.peerTools(self, message: message)
        case "call":
            guard let callID = LinkJSON.number(message["id"]), let tool = LinkJSON.string(message["tool"]) else { return }
            let input = message["input"] ?? .null
            let name = deviceName
            Task { [self] in
                do {
                    let output = try await service.runMacTool(tool, input: input, deviceName: name)
                    await send(["t": "result", "id": .number(callID), "ok": true, "output": output])
                } catch {
                    let (code, text) = LinkJSON.errorCode(error)
                    await send([
                        "t": "result", "id": .number(callID), "ok": false,
                        "error": ["code": .string(code), "message": .string(text)],
                    ])
                }
            }
        case "result":
            guard let callID = LinkJSON.number(message["id"]).map(Int.init), let entry = pending.removeValue(forKey: callID) else { return }
            if LinkJSON.bool(message["ok"]) == true {
                entry.continuation.resume(returning: message["output"] ?? .null)
            } else {
                let code = LinkJSON.string(message["error"]?["code"]) ?? "failed"
                let text = LinkJSON.string(message["error"]?["message"]) ?? "The phone could not run that."
                entry.continuation.resume(throwing: LinkJSON.toolError(code: code, message: text))
            }
        case "event":
            if let topic = LinkJSON.string(message["topic"]) { await service.peerEvent(topic: topic, data: message["data"] ?? .null) }
        case "ping":
            await send(["t": "pong"])
        case "bye":
            if LinkJSON.string(message["reason"]) == "unpair" { await service.peerUnpaired(self) }
            closed = true
            channel.close()
        default:
            break  // pong and unknown types are ignored
        }
    }

    private func handlePair(_ message: JSONValue, remoteKey: Data) async {
        guard !authenticated else { return }
        let token = LinkJSON.string(message["token"]) ?? ""
        let outcome = await service.completePairing(token: token, device: message["device"] ?? .null, remoteKey: remoteKey)
        switch outcome {
        case .paired(let device):
            authenticated = true
            deviceName = device.name
            await send(["t": "paired", "ok": true, "device": await service.deviceJSON()])
            await service.sessionAuthenticated(self, device: device)
            await send(await service.helloMessage())
        case .failed(let reason):
            await send(["t": "paired", "ok": false, "error": .string(reason)])
            closed = true
            channel.close()
        }
    }

    // MARK: Sending

    func send(_ message: JSONValue) async {
        guard let noise else { return }
        guard let sealed = try? noise.seal(plaintext: LinkJSON.encode(message)) else { return }
        lastSent = .now
        try? await channel.send(sealed)
    }

    /// Calls a tool on the phone and waits for its result.
    func call(tool: String, input: JSONValue) async throws -> JSONValue {
        guard authenticated, !closed else { throw ToolError.unavailable("No phone is connected.") }
        let callID = nextCallID
        nextCallID += 1
        let timeout = timing.callTimeout
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, any Error>) in
            pending[callID] = Pending(continuation: cont)
            Task { [self] in
                await send(["t": "call", "id": .number(Double(callID)), "tool": .string(tool), "input": input])
            }
            Task { [self] in
                try? await Task.sleep(for: timeout)
                expire(callID)
            }
        }
    }

    private func expire(_ callID: Int) {
        pending.removeValue(forKey: callID)?.continuation.resume(throwing: ToolError.unavailable("The phone did not answer in time."))
    }

    // MARK: Heartbeat

    private func heartbeatLoop() async {
        while !Task.isCancelled && !closed {
            let now = ContinuousClock.now
            let untilPing = timing.pingInterval - (now - lastSent)
            let untilSilence = timing.silenceTimeout - (now - lastReceived)
            let wait = min(max(untilPing, .zero), max(untilSilence, .zero))
            if wait > .zero { try? await Task.sleep(for: wait) }
            if Task.isCancelled || closed { return }
            let after = ContinuousClock.now
            if after - lastReceived >= timing.silenceTimeout {
                closed = true
                channel.close()
                return
            }
            if after - lastSent >= timing.pingInterval { await send(["t": "ping"]) }
        }
    }
}
