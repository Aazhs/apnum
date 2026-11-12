import ApnumCore
import Foundation

public actor TimerService {
    public static let minDuration: TimeInterval = 1
    public static let maxDuration: TimeInterval = 24 * 3600

    private struct FileState: Codable, Sendable {
        var timers: [CountdownTimer] = []
        var stopwatch = Stopwatch()
    }

    private let store: JSONFileStore<FileState>
    private let ringer: any Ringer
    private let changes: ChangeFeed
    private let clock: @Sendable () -> Date
    private var items: [CountdownTimer] = []
    private var watch = Stopwatch()

    public init(
        paths: AppPaths, ringer: any Ringer, changes: ChangeFeed,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = JSONFileStore(url: paths.file("timers.json"))
        self.ringer = ringer
        self.changes = changes
        self.clock = now
    }

    /// The injected clock's current time.
    public nonisolated var currentDate: Date { clock() }

    public func load() async throws {
        if let state = try await store.load() {
            items = state.timers
            watch = state.stopwatch
        }
    }

    // MARK: Reading

    /// Ringing first, then running by end time, then paused, then newest.
    public func timers() -> [CountdownTimer] {
        func rank(_ s: CountdownTimer.State) -> Int {
            switch s {
            case .ringing: 0
            case .running: 1
            case .paused: 2
            case .finished: 3
            }
        }
        return items.sorted { a, b in
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            if a.state == .running, let x = a.endsAt, let y = b.endsAt, x != y { return x < y }
            return a.createdAt > b.createdAt
        }
    }

    public func stopwatch() -> Stopwatch { watch }

    // MARK: Countdown timers

    @discardableResult
    public func start(duration: TimeInterval, label: String = "") async throws -> CountdownTimer {
        guard duration.isFinite, duration >= Self.minDuration, duration <= Self.maxDuration else {
            throw ToolError.invalidInput("Duration must be between 1 second and 24 hours.")
        }
        let date = clock()
        let timer = CountdownTimer(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines), duration: duration,
            state: .running, endsAt: date.addingTimeInterval(duration), createdAt: date)
        items.append(timer)
        try await commit()
        return timer
    }

    @discardableResult
    public func pause(id: UUID) async throws -> CountdownTimer {
        let i = try index(id)
        guard items[i].state == .running else { throw ToolError.invalidInput("Timer is not running.") }
        items[i].pausedRemaining = items[i].remaining(at: clock())
        items[i].endsAt = nil
        items[i].state = .paused
        try await commit()
        return items[i]
    }

    @discardableResult
    public func resume(id: UUID) async throws -> CountdownTimer {
        let i = try index(id)
        guard items[i].state == .paused else { throw ToolError.invalidInput("Timer is not paused.") }
        items[i].endsAt = clock().addingTimeInterval(items[i].pausedRemaining ?? items[i].duration)
        items[i].pausedRemaining = nil
        items[i].state = .running
        try await commit()
        return items[i]
    }

    /// Removes a timer; stops the ringer if it was ringing.
    public func cancel(id: UUID) async throws {
        let i = try index(id)
        let wasRinging = items[i].state == .ringing
        items.remove(at: i)
        if wasRinging { await ringer.stop(id: id.uuidString) }
        try await commit()
        if wasRinging { changes.publish(.ringing) }
    }

    /// Adds time to a running or paused timer. On a ringing timer it silences
    /// the ring and runs again for `seconds`.
    @discardableResult
    public func addTime(id: UUID, seconds: TimeInterval) async throws -> CountdownTimer {
        guard seconds.isFinite, seconds > 0, seconds <= Self.maxDuration else {
            throw ToolError.invalidInput("Seconds to add must be between 1 and 86400.")
        }
        let i = try index(id)
        let date = clock()
        switch items[i].state {
        case .running:
            items[i].endsAt = (items[i].endsAt ?? date).addingTimeInterval(seconds)
        case .paused:
            items[i].pausedRemaining = (items[i].pausedRemaining ?? 0) + seconds
        case .ringing:
            items[i].state = .running
            items[i].endsAt = date.addingTimeInterval(seconds)
            await ringer.stop(id: id.uuidString)
            changes.publish(.ringing)
        case .finished:
            throw ToolError.invalidInput("Timer has finished.")
        }
        items[i].duration += seconds
        try await commit()
        return items[i]
    }

    /// Silences a ringing timer and removes it.
    public func stopRinging(id: UUID) async throws {
        let i = try index(id)
        guard items[i].state == .ringing else { throw ToolError.invalidInput("Timer is not ringing.") }
        items[i].state = .finished
        items.remove(at: i)
        await ringer.stop(id: id.uuidString)
        try await commit()
        changes.publish(.ringing)
    }

    /// Starts a new timer with the same duration and label. A ringing original
    /// is stopped and removed; otherwise it is left alone.
    @discardableResult
    public func restart(id: UUID) async throws -> CountdownTimer {
        let i = try index(id)
        let old = items[i]
        if old.state == .ringing { try await stopRinging(id: id) }
        return try await start(duration: old.duration, label: old.label)
    }

    // MARK: Stopwatch

    public func stopwatchStart() async throws {
        guard !watch.isRunning else { return }
        watch.startedAt = clock()
        try await commit()
    }

    public func stopwatchPause() async throws {
        guard let started = watch.startedAt else { return }
        watch.accumulated += max(0, clock().timeIntervalSince(started))
        watch.startedAt = nil
        try await commit()
    }

    /// Records a lap; returns the cumulative elapsed time, or nil if not running.
    @discardableResult
    public func stopwatchLap() async throws -> TimeInterval? {
        guard watch.isRunning else { return nil }
        let elapsed = watch.elapsed(at: clock())
        watch.laps.append(elapsed)
        try await commit()
        return elapsed
    }

    public func stopwatchReset() async throws {
        watch = Stopwatch()
        try await commit()
    }

    // MARK: Scheduling

    public func nextWakeDate(after date: Date) -> Date? {
        items.lazy.filter { $0.state == .running }.compactMap(\.endsAt).min()
    }

    public func tick(now date: Date) async {
        var fired: [CountdownTimer] = []
        for i in items.indices where items[i].state == .running && (items[i].endsAt ?? .distantFuture) <= date {
            items[i].state = .ringing
            items[i].endsAt = nil
            fired.append(items[i])
        }
        guard !fired.isEmpty else { return }
        try? await store.save(FileState(timers: items, stopwatch: watch))
        changes.publish(.timers)
        for timer in fired {
            await ringer.start(RingRequest(
                id: timer.id.uuidString, kind: .timer,
                title: timer.label.isEmpty ? "Timer" : timer.label,
                body: "\(TimerFormat.string(timer.duration)) timer finished", canSnooze: false))
        }
        changes.publish(.ringing)
    }

    // MARK: Internals

    private func index(_ id: UUID) throws -> Int {
        guard let i = items.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound("No timer with id \(id.uuidString). Use timer.list to see current timers.")
        }
        return i
    }

    private func commit() async throws {
        try await store.save(FileState(timers: items, stopwatch: watch))
        changes.publish(.timers)
    }

    public nonisolated func makeTools() -> [AnyTool] {
        [
            AnyTool(TimerListTool(service: self)), AnyTool(TimerStartTool(service: self)),
            AnyTool(TimerPauseTool(service: self)), AnyTool(TimerResumeTool(service: self)),
            AnyTool(TimerCancelTool(service: self)), AnyTool(TimerAddTimeTool(service: self)),
            AnyTool(TimerStopTool(service: self)), AnyTool(StopwatchGetTool(service: self)),
            AnyTool(StopwatchControlTool(service: self)),
        ]
    }
}
