import Foundation
import Synchronization

/// Names a kind of data that changed. Services publish topics; the UI (and
/// later the phone link) subscribe and refresh.
public struct ChangeTopic: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let alarms: ChangeTopic = "alarms"
    public static let timers: ChangeTopic = "timers"
    public static let notes: ChangeTopic = "notes"
    public static let calendar: ChangeTopic = "calendar"
    public static let reminders: ChangeTopic = "reminders"
    public static let ringing: ChangeTopic = "ringing"
}

/// A broadcast channel: every subscriber receives every published topic.
public final class ChangeFeed: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<ChangeTopic>.Continuation]>([:])

    public init() {}

    public func publish(_ topic: ChangeTopic) {
        let current = subscribers.withLock { Array($0.values) }
        for continuation in current { continuation.yield(topic) }
    }

    public func subscribe() -> AsyncStream<ChangeTopic> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ChangeTopic.self, bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }
}
