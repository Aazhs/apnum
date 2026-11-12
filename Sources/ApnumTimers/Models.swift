import Foundation

public struct CountdownTimer: Identifiable, Sendable, Codable, Equatable {
    public enum State: String, Sendable, Codable, Equatable {
        case running, paused, ringing, finished
    }

    public var id: UUID
    public var label: String
    public var duration: TimeInterval
    public var state: State
    /// Set while running.
    public var endsAt: Date?
    /// Set while paused.
    public var pausedRemaining: TimeInterval?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), label: String = "", duration: TimeInterval, state: State = .running,
        endsAt: Date? = nil, pausedRemaining: TimeInterval? = nil, createdAt: Date
    ) {
        self.id = id
        self.label = label
        self.duration = duration
        self.state = state
        self.endsAt = endsAt
        self.pausedRemaining = pausedRemaining
        self.createdAt = createdAt
    }

    /// Seconds left at `date`; never negative.
    public func remaining(at date: Date) -> TimeInterval {
        switch state {
        case .running: max(0, (endsAt ?? date).timeIntervalSince(date))
        case .paused: max(0, pausedRemaining ?? duration)
        case .ringing, .finished: 0
        }
    }
}

public struct Stopwatch: Sendable, Codable, Equatable {
    public var startedAt: Date?
    public var accumulated: TimeInterval
    /// Each lap is the cumulative elapsed time at which it was taken.
    public var laps: [TimeInterval]

    public init(startedAt: Date? = nil, accumulated: TimeInterval = 0, laps: [TimeInterval] = []) {
        self.startedAt = startedAt
        self.accumulated = accumulated
        self.laps = laps
    }

    public var isRunning: Bool { startedAt != nil }

    public func elapsed(at date: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
}

public enum TimerFormat {
    /// "5:00", "0:05", "1:02:03". Rounds up so a countdown shows 0:00 only when done.
    public static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
