import ApnumAlarms
import ApnumCalendar
import ApnumCore
import ApnumNotes
import ApnumSystem
import ApnumTimers
import Foundation
import Observation

/// The composition root. Builds every service, registers all of their tools in
/// one `ToolRegistry`, drives alarms and timers with a `WakeScheduler`, and keeps
/// main-actor snapshots of service state for SwiftUI.
///
/// Views read the snapshot properties and perform every change with `run(_:_:)`,
/// which goes through the registry exactly as an agent or the phone would.
@MainActor @Observable
final class AppModel {
    // MARK: Services (not observed)

    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored let changes = ChangeFeed()
    @ObservationIgnored let audit: AuditLog
    @ObservationIgnored let registry: ToolRegistry
    @ObservationIgnored let ringer: MacRinger
    @ObservationIgnored let alarms: AlarmService
    @ObservationIgnored let timers: TimerService
    @ObservationIgnored let notes: NoteService
    @ObservationIgnored let calendar: CalendarService
    @ObservationIgnored private let scheduler = WakeScheduler()
    @ObservationIgnored private var started = false

    // MARK: Snapshots for the UI

    private(set) var alarmList: [Alarm] = []
    private(set) var alarmSettings = AlarmSettings()
    private(set) var alarmMirrorError: String?
    private(set) var nextAlarm: (alarm: Alarm, date: Date)?

    private(set) var timerList: [CountdownTimer] = []
    private(set) var stopwatch = Stopwatch(startedAt: nil, accumulated: 0, laps: [])

    private(set) var noteList: [Note] = []
    private(set) var noteTags: [String] = []

    private(set) var eventAccess: AccessState = .notDetermined
    private(set) var reminderAccess: AccessState = .notDetermined
    /// Events from the start of today through the next 7 days.
    private(set) var upcomingEvents: [CalendarEvent] = []
    /// Incomplete reminders across all lists.
    private(set) var openReminders: [Reminder] = []

    /// Alarms and timers that are ringing right now.
    private(set) var ringing: [RingRequest] = []

    private(set) var recentActivity: [AuditEntry] = []
    var lastError: String?

    var tools: [ToolDescriptor] { registry.descriptors }

    // MARK: Setup

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        audit = AuditLog(url: paths.auditLog)
        ringer = MacRinger()
        let shortcuts = ShortcutsCLI()
        alarms = AlarmService(paths: paths, ringer: ringer, changes: changes, mirror: ClockAppMirror(runner: shortcuts))
        timers = TimerService(paths: paths, ringer: ringer, changes: changes)
        notes = NoteService(paths: paths, changes: changes)
        calendar = CalendarService.live(changes: changes)
        let system = SystemService(control: LiveSystemControl(), shortcuts: shortcuts, notifier: ringer)
        registry = ToolRegistry(
            tools: alarms.makeTools() + timers.makeTools() + notes.makeTools() + calendar.makeTools() + system.makeTools(),
            audit: audit)
    }

    /// Loads data, subscribes to changes and starts the scheduler. Safe to call more than once.
    func start() async {
        guard !started else { return }
        started = true

        ringer.setResponder { [weak self] kind, id, response in
            await self?.respond(kind: kind, id: id, response: response)
        }

        do { try await alarms.load() } catch { report(error) }
        do { try await timers.load() } catch { report(error) }
        do { try await notes.load() } catch { report(error) }
        await calendar.startObservingChanges()

        let alarms = alarms, timers = timers
        scheduler.start(
            next: { now in
                let dates = [await alarms.nextWakeDate(after: now), await timers.nextWakeDate(after: now)].compactMap { $0 }
                return dates.min()
            },
            fire: { now in
                await alarms.tick(now: now)
                await timers.tick(now: now)
            })

        Task { [weak self, changes] in
            for await topic in changes.subscribe() {
                await self?.handle(topic)
            }
        }

        for topic in [ChangeTopic.alarms, .timers, .notes, .calendar, .reminders] { await refresh(topic) }
        await refreshActivity()
        _ = await ringer.requestNotificationPermission()
    }

    // MARK: Actions

    /// Runs a tool as the user. Returns its output, or nil after recording the error in `lastError`.
    @discardableResult
    func run(_ tool: String, _ input: JSONValue = .null) async -> JSONValue? {
        do {
            let output = try await registry.callJSON(tool, input: input, caller: .ui)
            lastError = nil
            await refreshActivity()
            return output
        } catch {
            report(error)
            await refreshActivity()
            return nil
        }
    }

    func setAlarmSettings(_ settings: AlarmSettings) async {
        do { try await alarms.setSettings(settings) } catch { report(error) }
    }

    func requestCalendarAccess() async {
        do {
            _ = try await calendar.requestEventAccess()
            _ = try await calendar.requestReminderAccess()
        } catch { report(error) }
        await refresh(.calendar)
        await refresh(.reminders)
    }

    func stopRinging(_ request: RingRequest) async {
        await respond(kind: request.kind, id: request.id, response: .stop)
    }

    func snooze(_ request: RingRequest) async {
        await respond(kind: request.kind, id: request.id, response: .snooze)
    }

    // MARK: Internals

    private func respond(kind: RingRequest.Kind, id: String, response: RingResponse) async {
        switch (kind, response) {
        case (.alarm, .stop): await run("alarm.stop", ["id": .string(id)])
        case (.alarm, .snooze): await run("alarm.snooze", ["id": .string(id)])
        case (.timer, _): await run("timer.stop", ["id": .string(id)])
        }
    }

    private func handle(_ topic: ChangeTopic) async {
        if topic == .alarms || topic == .timers { scheduler.poke() }
        if topic == .ringing {
            await refresh(.alarms)
            await refresh(.timers)
        } else {
            await refresh(topic)
        }
    }

    private func refresh(_ topic: ChangeTopic) async {
        switch topic {
        case .alarms:
            alarmList = await alarms.alarms()
            alarmSettings = await alarms.settings()
            alarmMirrorError = await alarms.lastMirrorError()
            nextAlarm = await alarms.nextAlarm(after: Date())
            await refreshRinging()
        case .timers:
            timerList = await timers.timers()
            stopwatch = await timers.stopwatch()
            await refreshRinging()
        case .notes:
            noteList = await notes.notes()
            noteTags = await notes.allTags()
        case .calendar:
            eventAccess = await calendar.eventAccess()
            guard eventAccess == .granted else { upcomingEvents = []; return }
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 8, to: start) ?? start
            do { upcomingEvents = try await calendar.events(from: start, to: end) } catch { report(error) }
        case .reminders:
            reminderAccess = await calendar.reminderAccess()
            guard reminderAccess == .granted else { openReminders = []; return }
            do { openReminders = try await calendar.reminders(listID: nil, includeCompleted: false) } catch { report(error) }
        default:
            break
        }
    }

    private func refreshRinging() async {
        let ringingTimers = timerList.filter { $0.state == .ringing }.map {
            RingRequest(
                id: $0.id.uuidString, kind: .timer, title: $0.label.isEmpty ? "Timer" : $0.label,
                body: "\(TimerFormat.string($0.duration)) timer finished", canSnooze: false)
        }
        ringing = await alarms.ringing() + ringingTimers
    }

    private func refreshActivity() async {
        recentActivity = await audit.recent(limit: 100)
    }

    private func report(_ error: any Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
