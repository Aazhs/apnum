import ApnumCore
import Foundation

/// apnum's own alarm clock. Owns the alarm list, rings alarms on the Mac and
/// can mirror them into the Clock app. Driven by `WakeScheduler` through
/// `nextWakeDate(after:)` and `tick(now:)`; never polls.
public actor AlarmService {
    /// A due time further in the past than this means the Mac was asleep: not rung.
    static let missedGrace: TimeInterval = 120

    private let alarmStore: JSONFileStore<[Alarm]>
    private let settingsStore: JSONFileStore<AlarmSettings>
    private let ringer: any Ringer
    private let changes: ChangeFeed
    private let mirror: (any AlarmMirror)?
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    private var all: [Alarm] = []
    private var currentSettings = AlarmSettings()
    private var ringingRequests: [String: RingRequest] = [:]
    private var lastTick: Date?
    private var mirrorError: String?

    /// `clock` supplies "now" for mutations (createdAt, snooze); tests inject a fixed one.
    public init(
        paths: AppPaths, ringer: any Ringer, changes: ChangeFeed, mirror: (any AlarmMirror)? = nil,
        calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        alarmStore = JSONFileStore(url: paths.file("alarms.json"))
        settingsStore = JSONFileStore(url: paths.file("alarm-settings.json"))
        self.ringer = ringer
        self.changes = changes
        self.mirror = mirror
        self.calendar = calendar
        self.clock = clock
    }

    // MARK: Reading

    public func load() async throws {
        all = try await alarmStore.load() ?? []
        currentSettings = try await settingsStore.load() ?? AlarmSettings()
    }

    /// Live alarms sorted by time of day.
    public func alarms() -> [Alarm] {
        all.filter { !$0.isDeleted }.sorted { ($0.hour, $0.minute, $0.createdAt) < ($1.hour, $1.minute, $1.createdAt) }
    }

    public func alarm(id: UUID) -> Alarm? { all.first { $0.id == id && !$0.isDeleted } }

    public func settings() -> AlarmSettings { currentSettings }

    public func ringing() -> [RingRequest] { ringingRequests.values.sorted { $0.id < $1.id } }

    public func lastMirrorError() -> String? { mirrorError }

    // MARK: Changing

    @discardableResult
    public func create(
        hour: Int, minute: Int, label: String = "", repeatDays: Set<Weekday> = [], snoozeMinutes: Int = 9,
        sound: String? = nil
    ) async throws -> Alarm {
        try Self.validate(hour: hour, minute: minute, snoozeMinutes: snoozeMinutes)
        let alarm = Alarm(
            hour: hour, minute: minute, label: label, repeatDays: repeatDays, snoozeMinutes: snoozeMinutes,
            sound: sound?.isEmpty == true ? nil : sound, createdAt: clock())
        try await commit(all + [alarm])
        return alarm
    }

    /// nil means unchanged. An empty `sound` clears it back to the default.
    @discardableResult
    public func update(
        id: UUID, hour: Int? = nil, minute: Int? = nil, label: String? = nil, repeatDays: Set<Weekday>? = nil,
        isEnabled: Bool? = nil, snoozeMinutes: Int? = nil, sound: String? = nil
    ) async throws -> Alarm {
        guard let index = all.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw ToolError.notFound("alarm \(id.uuidString)")
        }
        var a = all[index]
        try Self.validate(hour: hour ?? a.hour, minute: minute ?? a.minute, snoozeMinutes: snoozeMinutes ?? a.snoozeMinutes)
        let reschedules = hour != nil || minute != nil || repeatDays != nil || isEnabled == true
        a.hour = hour ?? a.hour
        a.minute = minute ?? a.minute
        a.label = label ?? a.label
        a.repeatDays = repeatDays ?? a.repeatDays
        a.isEnabled = isEnabled ?? a.isEnabled
        a.snoozeMinutes = snoozeMinutes ?? a.snoozeMinutes
        if let sound { a.sound = sound.isEmpty ? nil : sound }
        if reschedules || isEnabled == false {
            a.snoozedUntil = nil
            if reschedules { a.lastFiredAt = nil }
        }
        a.updatedAt = clock()
        var next = all
        next[index] = a
        try await commit(next)
        if isEnabled == false || reschedules { await stopRingerIfRinging(id) }
        return a
    }

    /// Tombstones the alarm (kept in the file so the phone can learn of the delete).
    public func delete(id: UUID) async throws {
        guard let index = all.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw ToolError.notFound("alarm \(id.uuidString)")
        }
        var next = all
        let now = clock()
        next[index].deletedAt = now
        next[index].updatedAt = now
        next[index].snoozedUntil = nil
        try await commit(next)
        await stopRingerIfRinging(id)
    }

    public func setSettings(_ new: AlarmSettings) async throws {
        let old = currentSettings
        try await settingsStore.save(new)
        currentSettings = new
        changes.publish(.alarms)
        if new.mirrorToClockApp {
            await syncMirror()
        } else if old.mirrorToClockApp {
            await syncMirror(force: true, empty: true)  // remove our alarms from the Clock app
        }
    }

    /// Stops the ringer. A one-shot alarm that has rung becomes disabled.
    public func stopRinging(id: UUID) async throws {
        guard let index = all.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw ToolError.notFound("alarm \(id.uuidString)")
        }
        let wasRinging = ringingRequests[id.uuidString] != nil
        await stopRingerIfRinging(id, always: true)
        var a = all[index]
        a.snoozedUntil = nil
        if a.isOneShot && (wasRinging || a.lastFiredAt != nil) { a.isEnabled = false }
        a.updatedAt = clock()
        var next = all
        next[index] = a
        try await commit(next)
    }

    /// Stops ringing and rings again in `snoozeMinutes`.
    public func snooze(id: UUID) async throws {
        guard let index = all.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw ToolError.notFound("alarm \(id.uuidString)")
        }
        guard all[index].snoozeMinutes > 0 else {
            throw ToolError.invalidInput("Snooze is disabled for this alarm (snoozeMinutes is 0).")
        }
        await stopRingerIfRinging(id, always: true)
        let now = clock()
        var next = all
        next[index].snoozedUntil = now.addingTimeInterval(TimeInterval(all[index].snoozeMinutes * 60))
        next[index].updatedAt = now
        try await commit(next)
    }

    /// Forces a mirror sync now. Returns nil on success or the error message.
    @discardableResult
    public func syncMirrorNow() async -> String? {
        await syncMirror(force: true)
        return mirrorError
    }

    // MARK: Scheduling

    /// The next time `alarm` rings after `date`, or nil if it never will.
    public nonisolated func nextFireDate(for alarm: Alarm, after date: Date) -> Date? {
        guard alarm.isEnabled, alarm.deletedAt == nil else { return nil }
        var candidates: [Date] = []
        if let s = alarm.snoozedUntil, s > date { candidates.append(s) }
        // A one-shot that has already rung only rings again through a snooze.
        if !(alarm.isOneShot && alarm.lastFiredAt != nil) {
            var base = DateComponents(hour: alarm.hour, minute: alarm.minute, second: 0)
            if alarm.isOneShot {
                if let d = calendar.nextDate(after: date, matching: base, matchingPolicy: .nextTime) { candidates.append(d) }
            } else {
                for day in alarm.repeatDays {
                    base.weekday = day.rawValue
                    if let d = calendar.nextDate(after: date, matching: base, matchingPolicy: .nextTime) { candidates.append(d) }
                }
            }
        }
        return candidates.min()
    }

    public func nextAlarm(after date: Date) -> (alarm: Alarm, date: Date)? {
        all.compactMap { a in nextFireDate(for: a, after: date).map { (alarm: a, date: $0) } }
            .min { $0.date < $1.date }
    }

    /// Earliest moment anything needs attention; the app sleeps until then.
    public func nextWakeDate(after date: Date) -> Date? { nextAlarm(after: date)?.date }

    /// Fires every alarm due in (last tick, now]. Anything due more than two
    /// minutes ago (the Mac was asleep) is recorded as missed instead of rung.
    public func tick(now: Date) async {
        var changed = false
        var fired = false
        let mirrorMode = currentSettings.mirrorToClockApp
        for index in all.indices {
            var from = max(lastTick ?? .distantPast, all[index].updatedAt, all[index].lastFiredAt ?? .distantPast)
            var iterations = 0
            while iterations < 400, let due = nextFireDate(for: all[index], after: from), due <= now {
                iterations += 1
                from = due
                var a = all[index]
                a.snoozedUntil = nil
                changed = true
                if now.timeIntervalSince(due) > Self.missedGrace {
                    a.lastFiredAt = due
                    if a.isOneShot { a.isEnabled = false }
                    all[index] = a
                    continue
                }
                a.lastFiredAt = now
                if mirrorMode, a.isOneShot { a.isEnabled = false }  // the Clock app owns ringing
                all[index] = a
                if !mirrorMode {
                    let request = RingRequest(
                        id: a.id.uuidString, kind: .alarm, title: a.label.isEmpty ? "Alarm" : a.label, body: a.timeText,
                        canSnooze: a.snoozeMinutes > 0, sound: a.sound)
                    ringingRequests[request.id] = request
                    await ringer.start(request)
                    fired = true
                }
                break
            }
        }
        lastTick = now
        guard changed else { return }
        try? await alarmStore.save(all)  // a failed write must not stop the clock
        changes.publish(.alarms)
        if fired { changes.publish(.ringing) }
        if mirrorMode { await syncMirror() }
    }

    // MARK: Internals

    private static func validate(hour: Int, minute: Int, snoozeMinutes: Int) throws {
        guard (0...23).contains(hour) else { throw ToolError.invalidInput("hour must be 0-23, got \(hour)") }
        guard (0...59).contains(minute) else { throw ToolError.invalidInput("minute must be 0-59, got \(minute)") }
        guard (0...180).contains(snoozeMinutes) else {
            throw ToolError.invalidInput("snoozeMinutes must be 0-180 (0 disables snooze), got \(snoozeMinutes)")
        }
    }

    private func commit(_ next: [Alarm]) async throws {
        try await alarmStore.save(next)
        all = next
        changes.publish(.alarms)
        await syncMirror()
    }

    private func stopRingerIfRinging(_ id: UUID, always: Bool = false) async {
        let key = id.uuidString
        guard ringingRequests.removeValue(forKey: key) != nil || always else { return }
        await ringer.stop(id: key)
        changes.publish(.ringing)
    }

    private func syncMirror(force: Bool = false, empty: Bool = false) async {
        guard let mirror, force || currentSettings.mirrorToClockApp else { return }
        let payload = empty ? [] : all.filter { $0.isEnabled && !$0.isDeleted }
        do {
            try await mirror.sync(payload)
            mirrorError = nil
        } catch {
            mirrorError = error.localizedDescription
        }
    }

    public nonisolated func makeTools() -> [AnyTool] {
        [
            AnyTool(AlarmListTool(service: self)), AnyTool(AlarmNextTool(service: self)),
            AnyTool(AlarmCreateTool(service: self)), AnyTool(AlarmUpdateTool(service: self)),
            AnyTool(AlarmDeleteTool(service: self)), AnyTool(AlarmStopTool(service: self)),
            AnyTool(AlarmSnoozeTool(service: self)), AnyTool(AlarmMirrorSyncTool(service: self)),
        ]
    }
}
