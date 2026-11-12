import ApnumCore
import Foundation
import Synchronization
import Testing
@testable import ApnumTimers

final class FakeClock: Sendable {
    private let t = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var date: Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
}

struct Harness {
    let clock: FakeClock
    let ringer = RecordingRinger()
    let paths: AppPaths
    let feed = ChangeFeed()
    let service: TimerService

    init(paths: AppPaths? = nil, clock: FakeClock? = nil) {
        let c = clock ?? FakeClock()
        self.clock = c
        let p = paths ?? AppPaths.temporary()
        self.paths = p
        service = TimerService(paths: p, ringer: ringer, changes: feed, now: { c.date })
    }
}

@Suite struct TimerServiceTests {
    @Test func startPauseResumeMath() async throws {
        let h = Harness()
        let t = try await h.service.start(duration: 300, label: "tea")
        #expect(t.remaining(at: h.clock.date) == 300)
        h.clock.advance(100)
        let p = try await h.service.pause(id: t.id)
        #expect(p.state == .paused && p.pausedRemaining == 200 && p.endsAt == nil)
        h.clock.advance(1000)
        #expect(p.remaining(at: h.clock.date) == 200)
        let r = try await h.service.resume(id: t.id)
        #expect(r.remaining(at: h.clock.date) == 200)
        #expect(r.endsAt == h.clock.date.addingTimeInterval(200))
        #expect(r.remaining(at: h.clock.date.addingTimeInterval(999)) == 0)
    }

    @Test func nextWakeDate() async throws {
        let h = Harness()
        #expect(await h.service.nextWakeDate(after: h.clock.date) == nil)
        let a = try await h.service.start(duration: 600)
        _ = try await h.service.start(duration: 60)
        let paused = try await h.service.start(duration: 5)
        try await h.service.pause(id: paused.id)
        #expect(await h.service.nextWakeDate(after: h.clock.date) == h.clock.date.addingTimeInterval(60))
        try await h.service.cancel(id: a.id)
    }

    @Test func tickRingsExactlyOnce() async throws {
        let h = Harness()
        let t = try await h.service.start(duration: 10, label: "")
        await h.service.tick(now: h.clock.date.addingTimeInterval(5))
        #expect(h.ringer.started.isEmpty)
        let later = h.clock.date.addingTimeInterval(10)
        await h.service.tick(now: later)
        await h.service.tick(now: later.addingTimeInterval(5))
        #expect(h.ringer.started.count == 1)
        let req = try #require(h.ringer.started.first)
        #expect(req.id == t.id.uuidString && req.kind == .timer && req.title == "Timer")
        #expect(req.body == "0:10 timer finished" && !req.canSnooze)
        #expect(await h.service.timers().first?.state == .ringing)
        #expect(await h.service.nextWakeDate(after: later) == nil)
    }

    @Test func cancelWhileRingingStopsRinger() async throws {
        let h = Harness()
        let t = try await h.service.start(duration: 5, label: "x")
        await h.service.tick(now: h.clock.date.addingTimeInterval(5))
        try await h.service.cancel(id: t.id)
        #expect(h.ringer.stopped == [t.id.uuidString])
        #expect(await h.service.timers().isEmpty)
    }

    @Test func stopRingingRemoves() async throws {
        let h = Harness()
        let t = try await h.service.start(duration: 5)
        await #expect(throws: ToolError.self) { try await h.service.stopRinging(id: t.id) }
        await h.service.tick(now: h.clock.date.addingTimeInterval(5))
        try await h.service.stopRinging(id: t.id)
        #expect(h.ringer.stopped == [t.id.uuidString])
        #expect(await h.service.timers().isEmpty)
    }

    @Test func addTime() async throws {
        let h = Harness()
        let t = try await h.service.start(duration: 60)
        let a = try await h.service.addTime(id: t.id, seconds: 30)
        #expect(a.remaining(at: h.clock.date) == 90)
        try await h.service.pause(id: t.id)
        let b = try await h.service.addTime(id: t.id, seconds: 10)
        #expect(b.pausedRemaining == 100)
        try await h.service.resume(id: t.id)
        await h.service.tick(now: h.clock.date.addingTimeInterval(100))
        let c = try await h.service.addTime(id: t.id, seconds: 60)
        #expect(c.state == .running && c.remaining(at: h.clock.date) == 60)
        #expect(h.ringer.stopped == [t.id.uuidString])
        await #expect(throws: ToolError.self) { try await h.service.addTime(id: t.id, seconds: 0) }
    }

    @Test func restart() async throws {
        let h = Harness()
        let t = try await h.service.start(duration: 20, label: "eggs")
        await h.service.tick(now: h.clock.date.addingTimeInterval(20))
        h.clock.advance(25)
        let n = try await h.service.restart(id: t.id)
        #expect(n.id != t.id && n.label == "eggs" && n.duration == 20 && n.state == .running)
        #expect(n.remaining(at: h.clock.date) == 20)
        #expect(await h.service.timers().count == 1)
    }

    @Test func persistenceRoundTrip() async throws {
        let h = Harness()
        let running = try await h.service.start(duration: 30, label: "soon")
        let paused = try await h.service.start(duration: 500)
        try await h.service.pause(id: paused.id)
        try await h.service.stopwatchStart()
        h.clock.advance(40)

        let h2 = Harness(paths: h.paths, clock: h.clock)
        try await h2.service.load()
        #expect(await h2.service.timers().count == 2)
        #expect(await h2.service.stopwatch().isRunning)
        #expect(await h2.service.nextWakeDate(after: h.clock.date) != nil)
        await h2.service.tick(now: h.clock.date)
        #expect(h2.ringer.started.map(\.id) == [running.id.uuidString])
        #expect(await h2.service.timers().first?.state == .ringing)
    }

    @Test func stopwatchLaps() async throws {
        let h = Harness()
        #expect(try await h.service.stopwatchLap() == nil)
        try await h.service.stopwatchStart()
        h.clock.advance(10)
        #expect(try await h.service.stopwatchLap() == 10)
        h.clock.advance(5)
        try await h.service.stopwatchPause()
        h.clock.advance(100)
        var s = await h.service.stopwatch()
        #expect(!s.isRunning && s.elapsed(at: h.clock.date) == 15 && s.laps == [10])
        try await h.service.stopwatchStart()
        h.clock.advance(1)
        s = await h.service.stopwatch()
        #expect(s.elapsed(at: h.clock.date) == 16)
        try await h.service.stopwatchReset()
        s = await h.service.stopwatch()
        #expect(s == Stopwatch())
    }

    @Test func durationValidation() async throws {
        let h = Harness()
        for bad in [0, 0.5, 86_401, -5, Double.nan] {
            await #expect(throws: ToolError.self) { try await h.service.start(duration: bad) }
        }
        _ = try await h.service.start(duration: 1)
        _ = try await h.service.start(duration: 86_400)
    }

    @Test func orderingAndPublishing() async throws {
        let h = Harness()
        var it = h.feed.subscribe().makeAsyncIterator()
        let a = try await h.service.start(duration: 100)
        h.clock.advance(1)
        let b = try await h.service.start(duration: 50)
        let c = try await h.service.start(duration: 10)
        try await h.service.pause(id: c.id)
        #expect(await h.service.timers().map(\.id) == [b.id, a.id, c.id])
        await h.service.tick(now: h.clock.date.addingTimeInterval(60))
        #expect(await h.service.timers().first?.id == b.id)
        #expect(await it.next() == .timers)
    }

    @Test func formatter() {
        #expect(TimerFormat.string(300) == "5:00")
        #expect(TimerFormat.string(3723) == "1:02:03")
        #expect(TimerFormat.string(-4) == "0:00")
        #expect(TimerFormat.string(4.2) == "0:05")
    }
}

@Suite struct TimerToolTests {
    func registry(_ h: Harness) -> ToolRegistry {
        ToolRegistry(tools: h.service.makeTools())
    }

    @Test func roundTrip() async throws {
        let h = Harness()
        let r = registry(h)
        #expect(r.descriptors.map(\.name) == [
            "stopwatch.control", "stopwatch.get", "timer.add_time", "timer.cancel", "timer.list",
            "timer.pause", "timer.resume", "timer.start", "timer.stop",
        ])
        let started = try await r.callJSON(
            "timer.start", input: ["minutes": 1, "seconds": 30, "hours": 1, "label": "pasta"], caller: .agent("a"))
        #expect(started["durationSeconds"] == 3690)
        guard case .string(let id)? = started["id"] else { Issue.record("no id"); return }

        _ = try await r.callJSON("timer.pause", input: ["id": .string(id)], caller: .ui)
        let list = try await r.callJSON("timer.list", caller: .ui)
        guard case .array(let arr)? = list["timers"], arr.count == 1 else { Issue.record("bad list"); return }
        #expect(arr[0]["state"] == "paused" && arr[0]["remainingSeconds"] == 3690)
        _ = try await r.callJSON("timer.resume", input: ["id": .string(id)], caller: .ui)
        _ = try await r.callJSON("timer.add_time", input: ["id": .string(id), "seconds": 10], caller: .ui)

        await h.service.tick(now: h.clock.date.addingTimeInterval(6000))
        _ = try await r.callJSON("timer.stop", input: ["id": .string(id)], caller: .ui)
        #expect(await h.service.timers().isEmpty)
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("timer.cancel", input: ["id": .string(id)], caller: .ui)
        }
    }

    @Test func invalidInputs() async throws {
        let h = Harness()
        let r = registry(h)
        await #expect(throws: ToolError.self) { _ = try await r.callJSON("timer.start", input: [:], caller: .ui) }
        await #expect(throws: ToolError.self) { _ = try await r.callJSON("timer.start", input: ["hours": 25], caller: .ui) }
        await #expect(throws: ToolError.self) { _ = try await r.callJSON("timer.pause", input: ["id": "nope"], caller: .ui) }
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("timer.pause", input: ["id": .string(UUID().uuidString)], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("stopwatch.control", input: ["action": "lap"], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("stopwatch.control", input: ["action": "jump"], caller: .ui)
        }
    }

    @Test func stopwatchTools() async throws {
        let h = Harness()
        let r = registry(h)
        _ = try await r.callJSON("stopwatch.control", input: ["action": "start"], caller: .ui)
        h.clock.advance(12)
        let lap = try await r.callJSON("stopwatch.control", input: ["action": "lap"], caller: .ui)
        #expect(lap["laps"] == [12])
        let got = try await r.callJSON("stopwatch.get", caller: .ui)
        #expect(got["running"] == true && got["elapsedSeconds"] == 12)
    }
}
