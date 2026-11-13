import ApnumCore
import Foundation
import Synchronization
import Testing
@testable import ApnumAlarms

private func makeCalendar(_ zone: String = "UTC") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

private let utc = makeCalendar()

/// 2025-01-15 is a Wednesday.
private func date(_ d: Int, _ h: Int, _ m: Int, _ s: Int = 0, month: Int = 1, cal: Calendar = utc) -> Date {
    cal.date(from: DateComponents(year: 2025, month: month, day: d, hour: h, minute: m, second: s))!
}

final class FakeShortcuts: ShortcutRunning {
    let installed: [String]
    let calls = Mutex<[(name: String, input: Data?)]>([])
    init(installed: [String] = ["apnum Sync Alarms"]) { self.installed = installed }
    func list() async throws -> [String] { installed }
    func run(_ name: String, input: Data?) async throws -> Data {
        calls.withLock { $0.append((name, input)) }
        return Data()
    }
}

final class FakeMirror: AlarmMirror {
    let syncs = Mutex<[[Alarm]]>([])
    let fail = Mutex(false)
    func sync(_ alarms: [Alarm]) async throws {
        syncs.withLock { $0.append(alarms) }
        if fail.withLock({ $0 }) { throw ToolError.unavailable("no shortcut") }
    }
}

final class Now: Sendable {
    let value: Mutex<Date>
    init(_ d: Date) { value = Mutex(d) }
    var date: Date { value.withLock { $0 } }
    func set(_ d: Date) { value.withLock { $0 = d } }
}

struct Fixture {
    let service: AlarmService
    let ringer = RecordingRinger()
    let paths = AppPaths.temporary()
    let now: Now
    let feed = ChangeFeed()

    init(mirror: (any AlarmMirror)? = nil, cal: Calendar = utc, start: Date = date(15, 6, 0)) {
        let now = Now(start)
        self.now = now
        service = AlarmService(paths: paths, ringer: ringer, changes: feed, mirror: mirror, calendar: cal, clock: { now.date })
    }
}

@Suite struct NextFireTests {
    let service = AlarmService(paths: .temporary(), ringer: RecordingRinger(), changes: ChangeFeed(), calendar: utc)

    func alarm(_ h: Int, _ m: Int, days: Set<Weekday> = [], enabled: Bool = true) -> Alarm {
        Alarm(hour: h, minute: m, repeatDays: days, isEnabled: enabled, createdAt: date(1, 0, 0))
    }

    @Test func oneShotToday() {
        #expect(service.nextFireDate(for: alarm(7, 30), after: date(15, 6, 0)) == date(15, 7, 30))
    }

    @Test func oneShotRollsOverMidnight() {
        #expect(service.nextFireDate(for: alarm(7, 30), after: date(15, 23, 0)) == date(16, 7, 30))
        // Exactly at the time is not "after".
        #expect(service.nextFireDate(for: alarm(7, 30), after: date(15, 7, 30)) == date(16, 7, 30))
    }

    @Test func repeatingPicksNextMatchingDay() {
        // Wednesday 12:00; Mon/Fri alarm -> Friday
        let a = alarm(7, 0, days: [.monday, .friday])
        #expect(service.nextFireDate(for: a, after: date(15, 12, 0)) == date(17, 7, 0))
    }

    @Test func repeatingWrapsAroundTheWeek() {
        // Friday 12:00 (17th); Monday-only -> Monday the 20th
        let a = alarm(7, 0, days: [.monday])
        #expect(service.nextFireDate(for: a, after: date(17, 12, 0)) == date(20, 7, 0))
        // Same-day later time still today
        #expect(service.nextFireDate(for: alarm(18, 0, days: [.wednesday]), after: date(15, 12, 0)) == date(15, 18, 0))
        // Same-day earlier time -> next week
        #expect(service.nextFireDate(for: alarm(6, 0, days: [.wednesday]), after: date(15, 12, 0)) == date(22, 6, 0))
    }

    @Test func snoozeIsHonoured() {
        var a = alarm(7, 0)
        a.snoozedUntil = date(15, 7, 9)
        #expect(service.nextFireDate(for: a, after: date(15, 7, 1)) == date(15, 7, 9))
        // An expired snooze is ignored.
        #expect(service.nextFireDate(for: a, after: date(15, 7, 10)) == date(16, 7, 0))
    }

    @Test func disabledOrDeletedNeverFires() {
        #expect(service.nextFireDate(for: alarm(7, 0, enabled: false), after: date(15, 0, 0)) == nil)
        var a = alarm(7, 0)
        a.deletedAt = date(10, 0, 0)
        #expect(service.nextFireDate(for: a, after: date(15, 0, 0)) == nil)
    }

    @Test func dstGapUsesNextTime() {
        let ny = makeCalendar("America/New_York")
        let s = AlarmService(paths: .temporary(), ringer: RecordingRinger(), changes: ChangeFeed(), calendar: ny)
        // 2025-03-09 02:30 does not exist in New York.
        let a = Alarm(hour: 2, minute: 30, createdAt: date(1, 0, 0, month: 3, cal: ny))
        let d = s.nextFireDate(for: a, after: date(9, 0, 0, month: 3, cal: ny))
        #expect(d != nil)
        #expect(d! > date(9, 0, 0, month: 3, cal: ny))
        #expect(d! <= date(9, 4, 0, month: 3, cal: ny))
    }

    @Test func nextWakeDateIsEarliest() async throws {
        let f = Fixture()
        try await f.service.create(hour: 9, minute: 0)
        try await f.service.create(hour: 7, minute: 15)
        let off = try await f.service.create(hour: 6, minute: 30)
        try await f.service.update(id: off.id, isEnabled: false)
        #expect(await f.service.nextWakeDate(after: date(15, 6, 0)) == date(15, 7, 15))
        #expect(await f.service.nextAlarm(after: date(15, 8, 0))?.date == date(15, 9, 0))
        #expect(await f.service.nextWakeDate(after: date(15, 9, 0)) == date(16, 7, 15))
    }

    @Test func noAlarmsNoWake() async {
        let f = Fixture()
        #expect(await f.service.nextWakeDate(after: date(15, 0, 0)) == nil)
    }
}

@Suite struct TickTests {
    @Test func firesExactlyOnce() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0, label: "Gym", snoozeMinutes: 5, sound: "Glass")
        await f.service.tick(now: date(15, 6, 59, 59))
        #expect(f.ringer.started.isEmpty)
        await f.service.tick(now: date(15, 7, 0, 1))
        await f.service.tick(now: date(15, 7, 0, 30))
        await f.service.tick(now: date(15, 7, 1))
        #expect(f.ringer.started == [
            RingRequest(id: a.id.uuidString, kind: .alarm, title: "Gym", body: "07:00", canSnooze: true, sound: "Glass")
        ])
        #expect(await f.service.ringing().count == 1)
        #expect(await f.service.alarm(id: a.id)?.lastFiredAt == date(15, 7, 0, 1))
    }

    @Test func defaultTitleAndNoSnoozeFlag() async throws {
        let f = Fixture()
        try await f.service.create(hour: 7, minute: 0, snoozeMinutes: 0)
        await f.service.tick(now: date(15, 7, 0))
        #expect(f.ringer.started.first?.title == "Alarm")
        #expect(f.ringer.started.first?.canSnooze == false)
    }

    @Test func repeatingFiresAgainNextDay() async throws {
        let f = Fixture()
        try await f.service.create(hour: 7, minute: 0, repeatDays: Set(Weekday.allCases))
        await f.service.tick(now: date(15, 7, 0))
        await f.service.tick(now: date(16, 7, 0))
        #expect(f.ringer.started.count == 2)
    }

    @Test func doesNotRingWhenMirroringToClockApp() async throws {
        let mirror = FakeMirror()
        let f = Fixture(mirror: mirror)
        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: true))
        let a = try await f.service.create(hour: 7, minute: 0)
        await f.service.tick(now: date(15, 7, 0))
        #expect(f.ringer.started.isEmpty)
        #expect(await f.service.ringing().isEmpty)
        #expect(await f.service.alarm(id: a.id)?.isEnabled == false)  // one-shot done
    }

    @Test func stillRingsWhenTheClockMirrorIsFailing() async throws {
        // Mirroring is on but the shortcut is missing: an alarm must never be silent.
        let mirror = FakeMirror()
        mirror.fail.withLock { $0 = true }
        let f = Fixture(mirror: mirror)
        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: true))
        let a = try await f.service.create(hour: 7, minute: 0)
        #expect(await f.service.lastMirrorError() != nil)
        await f.service.tick(now: date(15, 7, 0))
        #expect(f.ringer.started.count == 1)
        #expect(await f.service.alarm(id: a.id)?.isEnabled == true)  // still ours until stopped

        // Once the mirror works again the Clock app takes over.
        mirror.fail.withLock { $0 = false }
        _ = await f.service.syncMirrorNow()
        try await f.service.stopRinging(id: a.id)
        let b = try await f.service.create(hour: 8, minute: 0)
        await f.service.tick(now: date(15, 8, 0))
        #expect(f.ringer.started.count == 1)
        #expect(await f.service.alarm(id: b.id)?.isEnabled == false)
    }

    @Test func missedWhileAsleepIsNotRung() async throws {
        let f = Fixture()
        let once = try await f.service.create(hour: 7, minute: 0)
        let daily = try await f.service.create(hour: 7, minute: 0, repeatDays: Set(Weekday.allCases))
        await f.service.tick(now: date(15, 6, 30))
        await f.service.tick(now: date(15, 9, 0))  // Mac slept through 07:00
        #expect(f.ringer.started.isEmpty)
        let o = await f.service.alarm(id: once.id)
        #expect(o?.isEnabled == false)
        #expect(o?.lastFiredAt == date(15, 7, 0))
        #expect(await f.service.alarm(id: daily.id)?.lastFiredAt == date(15, 7, 0))
        // The repeating alarm still rings tomorrow.
        await f.service.tick(now: date(16, 7, 0))
        #expect(f.ringer.started.map(\.id) == [daily.id.uuidString])
    }

    @Test func firstTickAfterLoadOnlyFiresRecentlyDue() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0)
        let b = try await f.service.create(hour: 7, minute: 1)
        // New service instance: no tick history, like after app launch.
        let again = AlarmService(
            paths: f.paths, ringer: f.ringer, changes: f.feed, calendar: utc, clock: { f.now.date })
        try await again.load()
        await again.tick(now: date(15, 7, 1, 30))
        // 07:00 was 90s ago (within 2 min) and 07:01 was 30s ago.
        #expect(Set(f.ringer.started.map(\.id)) == [a.id.uuidString, b.id.uuidString])
        let late = AlarmService(paths: f.paths, ringer: RecordingRinger(), changes: f.feed, calendar: utc, clock: { f.now.date })
        try await late.load()
        await late.tick(now: date(15, 7, 10))
        #expect(await late.ringing().isEmpty)
    }
}

@Suite struct ActionTests {
    @Test func oneShotDisablesAfterStop() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0)
        await f.service.tick(now: date(15, 7, 0))
        // Still enabled while ringing, but would not ring again tomorrow.
        #expect(await f.service.nextWakeDate(after: date(15, 7, 1)) == nil)
        try await f.service.stopRinging(id: a.id)
        #expect(f.ringer.stopped == [a.id.uuidString])
        #expect(await f.service.alarm(id: a.id)?.isEnabled == false)
        #expect(await f.service.ringing().isEmpty)
    }

    @Test func repeatingStaysEnabledAfterStop() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0, repeatDays: [.wednesday])
        await f.service.tick(now: date(15, 7, 0))
        try await f.service.stopRinging(id: a.id)
        #expect(await f.service.alarm(id: a.id)?.isEnabled == true)
    }

    @Test func snoozeRingsAgain() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0, snoozeMinutes: 9)
        f.now.set(date(15, 7, 0))
        await f.service.tick(now: date(15, 7, 0))
        try await f.service.snooze(id: a.id)
        #expect(f.ringer.stopped == [a.id.uuidString])
        #expect(await f.service.alarm(id: a.id)?.snoozedUntil == date(15, 7, 9))
        #expect(await f.service.nextWakeDate(after: date(15, 7, 1)) == date(15, 7, 9))
        await f.service.tick(now: date(15, 7, 5))
        #expect(f.ringer.started.count == 1)
        await f.service.tick(now: date(15, 7, 9))
        #expect(f.ringer.started.count == 2)
        #expect(await f.service.alarm(id: a.id)?.snoozedUntil == nil)
    }

    @Test func snoozeDisabledThrows() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0, snoozeMinutes: 0)
        await #expect(throws: ToolError.self) { try await f.service.snooze(id: a.id) }
    }

    @Test func validation() async {
        let f = Fixture()
        await #expect(throws: ToolError.self) { try await f.service.create(hour: 24, minute: 0) }
        await #expect(throws: ToolError.self) { try await f.service.create(hour: 1, minute: 60) }
        await #expect(throws: ToolError.self) { try await f.service.create(hour: 1, minute: 0, snoozeMinutes: -1) }
    }

    @Test func updateKeepsUnspecifiedFields() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0, label: "A", repeatDays: [.monday], sound: "Glass")
        let u = try await f.service.update(id: a.id, minute: 30)
        #expect(u.hour == 7 && u.minute == 30 && u.label == "A" && u.repeatDays == [.monday] && u.sound == "Glass")
        let cleared = try await f.service.update(id: a.id, sound: "")
        #expect(cleared.sound == nil)
    }

    @Test func deleteIsATombstone() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0)
        try await f.service.delete(id: a.id)
        #expect(await f.service.alarms().isEmpty)
        #expect(await f.service.alarm(id: a.id) == nil)
        #expect(await f.service.nextWakeDate(after: date(15, 0, 0)) == nil)
        let stored = try await JSONFileStore<[Alarm]>(url: f.paths.file("alarms.json")).load()
        #expect(stored?.count == 1)
        #expect(stored?.first?.deletedAt != nil)
        await #expect(throws: ToolError.self) { try await f.service.delete(id: a.id) }
    }

    @Test func alarmsAreSortedAndPersist() async throws {
        let f = Fixture()
        try await f.service.create(hour: 9, minute: 0, label: "late")
        try await f.service.create(hour: 6, minute: 45, label: "early", repeatDays: [.monday, .sunday])
        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: true))

        let again = AlarmService(paths: f.paths, ringer: f.ringer, changes: f.feed, calendar: utc)
        try await again.load()
        #expect(await again.alarms().map(\.label) == ["early", "late"])
        #expect(await again.alarms().first?.repeatDays == [.monday, .sunday])
        #expect(await again.settings().mirrorToClockApp)
    }

    @Test func missingFilesLoadEmpty() async throws {
        let f = Fixture()
        try await f.service.load()
        #expect(await f.service.alarms().isEmpty)
        #expect(await f.service.settings() == AlarmSettings())
    }

    @Test func mutationsPublishChanges() async throws {
        let f = Fixture()
        var it = f.feed.subscribe().makeAsyncIterator()
        try await f.service.create(hour: 7, minute: 0)
        #expect(await it.next() == .alarms)
    }

    @Test func weekdayNames() {
        #expect(Weekday.monday.shortName == "Mon")
        #expect(Weekday.monday.wireName == "monday")
        #expect(Weekday(name: "FRI") == .friday)
        #expect(Weekday.sunday.rawValue == 1 && Weekday.saturday.rawValue == 7)
    }
}

@Suite struct MirrorTests {
    @Test func mirrorGetsEnabledAlarmsOnlyWhenEnabledInSettings() async throws {
        let mirror = FakeMirror()
        let f = Fixture(mirror: mirror)
        try await f.service.create(hour: 7, minute: 0)
        #expect(mirror.syncs.withLock { $0.count } == 0)  // setting off

        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: true))
        let off = try await f.service.create(hour: 8, minute: 0, label: "off")
        try await f.service.update(id: off.id, isEnabled: false)
        let last = mirror.syncs.withLock { $0.last }
        #expect(last?.map(\.hour) == [7])

        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: false))
        #expect(mirror.syncs.withLock { $0.last }?.isEmpty == true)  // cleaned up the Clock app
    }

    @Test func mirrorFailureDoesNotFailMutation() async throws {
        let mirror = FakeMirror()
        mirror.fail.withLock { $0 = true }
        let f = Fixture(mirror: mirror)
        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: true))
        let a = try await f.service.create(hour: 7, minute: 0)
        #expect(await f.service.alarm(id: a.id) != nil)
        #expect(await f.service.lastMirrorError()?.contains("no shortcut") == true)
        mirror.fail.withLock { $0 = false }
        #expect(await f.service.syncMirrorNow() == nil)
        #expect(await f.service.lastMirrorError() == nil)
    }

    @Test func shortcutReceivesExpectedJSON() async throws {
        let runner = FakeShortcuts()
        let f = Fixture(mirror: ClockAppMirror(runner: runner))
        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: true))
        try await f.service.create(hour: 7, minute: 30, label: "Gym", repeatDays: [.friday, .monday])
        try await f.service.create(hour: 6, minute: 0)
        let call = try #require(runner.calls.withLock { $0.last })
        #expect(call.name == "apnum Sync Alarms")
        let json = try JSONDecoder().decode(JSONValue.self, from: try #require(call.input))
        #expect(json == [
            "alarms": [
                ["hour": 7, "minute": 30, "label": "Gym [apnum]", "repeatDays": ["Monday", "Friday"]],
                ["hour": 6, "minute": 0, "label": "Alarm [apnum]", "repeatDays": []],
            ]
        ])
    }

    @Test func missingShortcutIsUnavailable() async throws {
        let mirror = ClockAppMirror(runner: FakeShortcuts(installed: ["Other"]))
        await #expect(throws: ToolError.self) { try await mirror.sync([]) }
        do { try await mirror.sync([]) } catch let ToolError.unavailable(message) {
            #expect(message.contains("docs/clock-shortcuts.md"))
        }
    }
}

@Suite struct ToolTests {
    func registry(_ f: Fixture) -> ToolRegistry { ToolRegistry(tools: f.service.makeTools()) }

    @Test func toolNamesAndSchemas() {
        let r = registry(Fixture())
        #expect(r.descriptors.map(\.name) == [
            "alarm.create", "alarm.delete", "alarm.list", "alarm.mirror.sync", "alarm.next", "alarm.snooze",
            "alarm.stop", "alarm.sync", "alarm.update",
        ])
        #expect(r.descriptor(named: "alarm.create")?.inputSchema["required"] == ["hour", "minute"])
        #expect(r.descriptor(named: "alarm.list")?.tier == .read)
        #expect(r.descriptor(named: "alarm.update")?.tier == .write)
    }

    @Test func createListUpdateDeleteRoundTrip() async throws {
        let f = Fixture()
        let r = registry(f)
        let created = try await r.callJSON(
            "alarm.create", input: ["hour": 7, "minute": 30, "label": "Gym", "repeatDays": ["monday", "Fri"]], caller: .agent("t"))
        #expect(created["time"] == "07:30")
        #expect(created["repeatDays"] == ["monday", "friday"])
        guard case .string(let id)? = created["id"] else { Issue.record("no id"); return }

        let listed = try await r.callJSON("alarm.list", caller: .agent("t"))
        guard case .array(let items)? = listed["alarms"] else { Issue.record("no alarms"); return }
        #expect(items.count == 1)
        #expect(items[0]["nextFireDate"] != nil)

        let next = try await r.callJSON("alarm.next", caller: .agent("t"))
        #expect(next["alarm"]?["id"] == .string(id))

        let off = try await r.callJSON("alarm.update", input: ["id": .string(id), "isEnabled": false], caller: .ui)
        #expect(off["isEnabled"] == false)
        #expect(try await r.callJSON("alarm.next", caller: .ui)["alarm"] == nil)

        _ = try await r.callJSON("alarm.delete", input: ["id": .string(id)], caller: .ui)
        #expect(await f.service.alarms().isEmpty)
    }

    @Test func invalidInputsAreRejected() async throws {
        let r = registry(Fixture())
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("alarm.create", input: ["hour": 25, "minute": 0], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("alarm.create", input: ["hour": 7, "minute": 0, "repeatDays": ["funday"]], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("alarm.stop", input: ["id": "not-a-uuid"], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("alarm.create", input: ["minute": 0], caller: .ui)
        }
    }

    @Test func stopAndSnoozeTools() async throws {
        let f = Fixture()
        let a = try await f.service.create(hour: 7, minute: 0)
        let r = registry(f)
        await f.service.tick(now: date(15, 7, 0))
        let ack = try await r.callJSON("alarm.snooze", input: ["id": .string(a.id.uuidString)], caller: .ui)
        #expect(ack["ok"] == true)
        _ = try await r.callJSON("alarm.stop", input: ["id": .string(a.id.uuidString)], caller: .ui)
        #expect(f.ringer.stopped.count == 2)
    }

    @Test func mirrorSyncToolReportsFailure() async throws {
        let f = Fixture(mirror: ClockAppMirror(runner: FakeShortcuts(installed: [])))
        let out = try await registry(f).callJSON("alarm.mirror.sync", caller: .ui)
        #expect(out["ok"] == false)
        guard case .string(let message)? = out["message"] else { Issue.record("no message"); return }
        #expect(message.contains("clock-shortcuts"))
    }
}
