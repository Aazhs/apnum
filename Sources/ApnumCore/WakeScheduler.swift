import Foundation
import Synchronization

/// Wakes up only when something is due, so apnum uses no CPU while idle.
///
/// Time-based services (alarms, timers) expose `nextWakeDate(after:)` and
/// `tick(now:)`. The app hands them to `start`: the scheduler calls `fire`,
/// asks `next` for the earliest wake date, and sleeps until then (capped at
/// `maxSleep`, which also absorbs wall-clock changes). Call `poke()` after any
/// change that could move the next wake date earlier. Sleeping uses the
/// continuous clock, so anything that came due while the Mac slept fires
/// right after it wakes.
public final class WakeScheduler: Sendable {
    private let maxSleep: TimeInterval
    private let signal = WakeSignal()
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(maxSleep: TimeInterval = 60) { self.maxSleep = maxSleep }

    public func start(
        next: @escaping @Sendable (Date) async -> Date?,
        fire: @escaping @Sendable (Date) async -> Void
    ) {
        let cap = maxSleep
        let signal = signal
        let newTask = Task {
            while !Task.isCancelled {
                await fire(Date())
                let now = Date()
                let target = await next(now)
                let wait = min(max(target.map { $0.timeIntervalSince(now) } ?? cap, 0), cap)
                guard wait > 0 else { continue }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { try? await Task.sleep(for: .seconds(wait)) }
                    group.addTask { await signal.wait() }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
        }
        task.withLock { $0?.cancel(); $0 = newTask }
    }

    /// Re-check the next wake date now.
    public func poke() { signal.fire() }

    public func stop() { task.withLock { $0?.cancel(); $0 = nil } }

    deinit { task.withLock { $0?.cancel() } }
}

/// A one-waiter wake-up signal. A `fire()` with no waiter is remembered,
/// so a poke that lands between sleeps is not lost.
final class WakeSignal: Sendable {
    private struct State {
        var pending = false
        var cancelled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func fire() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard let w = s.waiter else { s.pending = true; return nil }
            s.waiter = nil
            return w
        }
        waiter?.resume()
    }

    func wait() async {
        state.withLock { $0.cancelled = false }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.pending || s.cancelled {
                        s.pending = false
                        return true
                    }
                    s.waiter = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.cancelled = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume()
        }
    }
}
