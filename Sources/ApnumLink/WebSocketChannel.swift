import Foundation
import Network

/// One WebSocket connection carrying binary messages. Wraps an `NWConnection`
/// (server side or client side) and exposes received messages as an `AsyncStream`.
final class WebSocketChannel: Sendable {
    let connection: NWConnection
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let ready: AsyncStream<Bool>
    private let readyContinuation: AsyncStream<Bool>.Continuation
    private let queue = DispatchQueue(label: "dev.apnum.link.channel")

    static let maximumMessageSize = 16 * 1024 * 1024

    static func webSocketParameters(server: Bool = false) -> NWParameters {
        let params = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = maximumMessageSize
        if server {
            // Accept any path and any client: authentication is the Noise handshake, not HTTP.
            options.setClientRequestHandler(DispatchQueue(label: "dev.apnum.link.upgrade")) { _, _ in
                NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
        }
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return params
    }

    init(connection: NWConnection) {
        self.connection = connection
        (incoming, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        (ready, readyContinuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Client side: connects to a host and port.
    static func client(host: String, port: UInt16) -> WebSocketChannel {
        let url = URL(string: "ws://\(host):\(port)/link")!
        let connection = NWConnection(to: .url(url), using: webSocketParameters())
        return WebSocketChannel(connection: connection)
    }

    /// Starts the connection and the receive loop.
    func start() {
        let continuation = continuation, readyContinuation = readyContinuation
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                readyContinuation.yield(true)
                self?.receiveNext()
            case .failed, .cancelled:
                readyContinuation.yield(false)
                readyContinuation.finish()
                continuation.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Waits until the connection is usable. Returns false if it failed first.
    func waitUntilReady() async -> Bool {
        for await value in ready { return value }
        return false
    }

    private func receiveNext() {
        let continuation = continuation, connection = connection
        connection.receiveMessage { [weak self] data, context, _, error in
            var keepGoing = error == nil
            if let context,
                let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            {
                switch meta.opcode {
                case .binary: if let data { continuation.yield(data) }
                case .close:
                    keepGoing = false
                    continuation.finish()
                default: break
                }
            }
            if keepGoing { self?.receiveNext() } else {
                continuation.finish()
                connection.cancel()
            }
        }
    }

    func send(_ data: Data) async throws {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Sends a close frame and tears the connection down.
    func close() {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        let connection = connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        continuation.finish()
        // If the peer never reads the close frame, cancel anyway.
        queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
    }
}

/// Accepts WebSocket connections on a port and advertises the service with Bonjour.
final class LinkServer: Sendable {
    private let listener = LockedBox<NWListener?>(nil)
    private let queue = DispatchQueue(label: "dev.apnum.link.listener")

    /// Starts listening. Tries `port` first and falls back to any free port. Returns the real port.
    func start(
        port: UInt16, bonjourName: String?, txt: [String: String],
        onConnection: @escaping @Sendable (WebSocketChannel) -> Void
    ) async throws -> UInt16 {
        do {
            return try await listen(port: port, bonjourName: bonjourName, txt: txt, onConnection: onConnection)
        } catch {
            guard port != 0 else { throw error }
            return try await listen(port: 0, bonjourName: bonjourName, txt: txt, onConnection: onConnection)
        }
    }

    private func listen(
        port: UInt16, bonjourName: String?, txt: [String: String],
        onConnection: @escaping @Sendable (WebSocketChannel) -> Void
    ) async throws -> UInt16 {
        let params = WebSocketChannel.webSocketParameters(server: true)
        params.allowLocalEndpointReuse = true
        let listener = port == 0 ? try NWListener(using: params) : try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        if let bonjourName {
            listener.service = NWListener.Service(name: bonjourName, type: "_apnum._tcp", txtRecord: NWTXTRecord(txt))
        }
        listener.newConnectionHandler = { connection in
            let channel = WebSocketChannel(connection: connection)
            channel.start()
            onConnection(channel)
        }
        let result: UInt16 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, any Error>) in
            let once = LockedBox(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.exchange(true) == false { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.exchange(true) == false { cont.resume(throwing: error) }
                    listener.cancel()
                default: break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        self.listener.set(listener)
        return result
    }

    func stop() {
        listener.exchange(nil)?.cancel()
    }
}

/// A tiny lock-protected value.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    @discardableResult func exchange(_ new: Value) -> Value { lock.withLock { let old = value; value = new; return old } }
}
