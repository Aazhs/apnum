import ApnumAlarms
import ApnumCalendar
import ApnumCore
import ApnumLink
import ApnumNotes
import ApnumSky
import ApnumSystem
import ApnumTimers
import Foundation
import Observation
import AppKit

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
    @ObservationIgnored let sky: SkyService
    @ObservationIgnored let link: LinkService
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
    /// Bumped whenever calendar data changes, so views that fetch their own ranges can reload.
    private(set) var calendarRevision = 0
    /// Incomplete reminders across all lists.
    private(set) var openReminders: [Reminder] = []

    /// The live sky. The window theme, sidebar and menu bar follow this, never the preview.
    private(set) var skyScene: SkyScene?
    /// The sky at the time being scrubbed to on Today, nil while live. Only the Today hero reads these two,
    /// so scrubbing does not invalidate the rest of the app.
    private(set) var previewScene: SkyScene?
    private(set) var previewSummary: SkySummary?
    private(set) var skySummary: SkySummary?
    private(set) var skySettings: SkySettings?
    /// The real sky colour from midnight to midnight, for the day ribbon.
    private(set) var skyDayColors: [RGB] = []
    /// A time the user is scrubbing to on Today; nil means now.
    var skyPreview: Date? {
        didSet { if skyPreview != oldValue { skyPreviewChanged() } }
    }
    @ObservationIgnored private var previewWorker: Task<Void, Never>?
    @ObservationIgnored private var previewDirty = false
    /// Debug (APNUM_SKY_TIME): the live sky is shown at this time instead of now.
    @ObservationIgnored private var debugSkyDate: Date?

    /// Alarms and timers that are ringing right now.
    private(set) var ringing: [RingRequest] = []

    // Phone link
    var linkStatus: LinkStatus = .off
    var linkSettings = LinkSettings()
    var pairedDevice: PairedDevice?
    var linkFingerprint: String?
    var phone = PhoneState()
    /// The pairing code and QR link while a pairing is open.
    var pairingOffer: PairingOffer?
    /// The 6-digit number to compare with the phone when it paired by typing the code.
    var pairingSafety: String?
    /// Every tool available right now, including the phone's while it is connected.
    var tools: [ToolDescriptor] = []
    /// APNUM_DEMO=1 with APNUM_PHONE_DEMO=connected shows a made-up connected phone, with no networking.
    @ObservationIgnored let phoneDemo = ProcessInfo.processInfo.environment["APNUM_DEMO"] == "1"
        && ProcessInfo.processInfo.environment["APNUM_PHONE_DEMO"] == "connected"

    private(set) var recentActivity: [AuditEntry] = []
    var lastError: String?

    /// The section shown in the main window. APNUM_SECTION picks the first one (for screenshots).
    /// A note the Notes screen should open (set by Today when a note is clicked).
    var focusNoteID: UUID?

    var section: AppSection = AppSection(rawValue: ProcessInfo.processInfo.environment["APNUM_SECTION"] ?? "") ?? .today

    /// APNUM_DEMO=1 uses sample calendar data and seeds alarms, timers and notes into an empty data folder.
    @ObservationIgnored let isDemo = ProcessInfo.processInfo.environment["APNUM_DEMO"] == "1"

    // MARK: Setup

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        audit = AuditLog(url: paths.auditLog)
        ringer = MacRinger()
        let shortcuts = ShortcutsCLI()
        alarms = AlarmService(paths: paths, ringer: ringer, changes: changes, mirror: ClockAppMirror(runner: shortcuts))
        timers = TimerService(paths: paths, ringer: ringer, changes: changes)
        notes = NoteService(paths: paths, changes: changes)
        calendar = ProcessInfo.processInfo.environment["APNUM_DEMO"] == "1"
            ? CalendarService(backend: InMemoryCalendarBackend.demo(), changes: changes)
            : CalendarService.live(changes: changes)
        sky = SkyService(
            paths: paths, changes: changes,
            weather: ProcessInfo.processInfo.environment["APNUM_DEMO"] == "1" ? nil : OpenMeteoWeather())
        let system = SystemService(control: LiveSystemControl(), shortcuts: shortcuts, notifier: ringer)
        let isDemo = ProcessInfo.processInfo.environment["APNUM_DEMO"] == "1"
        let link = LinkService(
            paths: paths, changes: changes, keys: isDemo ? FileKeyStore(paths: paths) : KeychainKeyStore(), bonjour: !isDemo)
        self.link = link
        registry = ToolRegistry(
            tools: alarms.makeTools() + timers.makeTools() + notes.makeTools() + calendar.makeTools() + sky.makeTools()
                + system.makeTools() + link.makeTools(),
            policy: DefaultPermissionPolicy(trusted: { caller in await link.isTrusted(caller: caller) }),
            audit: audit)
        tools = registry.descriptors
        let alarms = alarms, timers = timers
        Task {
            await link.setRingingProvider {
                let alarmItems = await alarms.ringing()
                let timerItems = await timers.timers().filter { $0.state == .ringing }.map {
                    RingRequest(
                        id: $0.id.uuidString, kind: .timer, title: $0.label.isEmpty ? "Timer" : $0.label,
                        body: "\(TimerFormat.string($0.duration)) timer finished", canSnooze: false)
                }
                return (alarmItems + timerItems).map {
                    [
                        "id": .string($0.id), "kind": .string($0.kind.rawValue), "title": .string($0.title),
                        "body": .string($0.body), "canSnooze": .bool($0.canSnooze),
                    ]
                }
            }
        }
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
        await sky.load()
        // Debug only: APNUM_SKY_TIME=HH:mm opens with the sky previewed at that time (scripts/snapshot.sh).
        if let t = ProcessInfo.processInfo.environment["APNUM_SKY_TIME"], t.count == 5,
            let h = Int(t.prefix(2)), let m = Int(t.suffix(2)) {
            debugSkyDate = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())
            skyPreview = debugSkyDate
        }
        await refreshSky()
        if ProcessInfo.processInfo.environment["APNUM_SCRUB"] == "1" { startScrub() }
        Task { [weak self, sky] in
            // The sky moves slowly: recompute once a minute, and let the service
            // decide when the weather is stale (every 15 minutes at most).
            while !Task.isCancelled {
                if await sky.refreshWeather() { await self?.refreshSky() }
                try? await Task.sleep(for: .seconds(60))
                await self?.refreshSky()
            }
        }

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

        switch ProcessInfo.processInfo.environment["APNUM_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if isDemo { await DemoData.seedIfEmpty(self) }

        await startLink()
        for topic in [ChangeTopic.alarms, .timers, .notes, .calendar, .reminders] { await refresh(topic) }
        await refreshActivity()
        if !isDemo { _ = await ringer.requestNotificationPermission() }
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

    func setSkyLocation(_ location: GeoLocation) async {
        await sky.setLocation(location)
        _ = await sky.refreshWeather(force: true)
        await refreshSky()
    }

    func setLiveWeather(_ on: Bool) async {
        await sky.setLiveWeather(on)
        if on { _ = await sky.refreshWeather(force: true) }
        await refreshSky()
    }

    /// Debug (APNUM_SCRUB=1): moves the sky preview through the day in 5-minute steps, 30 steps per second,
    /// so the time-travel slider workload can be reproduced and measured without a human.
    private func startScrub() {
        Task { [weak self] in
            var minute = 0
            while !Task.isCancelled {
                guard let self else { return }
                skyPreview = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minute) * 60)
                Perf.count("scrub-set")
                minute = (minute + 5) % 1440
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func refreshSky() async {
        let date = debugSkyDate ?? Date()
        let (scene, summary) = await sky.snapshot(at: date)
        skyScene = scene
        skySummary = summary
        skySettings = await sky.settings()
        let colors = await sky.dayColors(for: date)
        if colors != skyDayColors { skyDayColors = colors }
    }

    /// Scrubbing: remember the latest requested time and let one worker catch up to it. Values that arrive
    /// while a scene is being computed are dropped, so the slider never queues work; the scene is computed
    /// off the main actor (in `SkyService`) and only the newest result is applied, at most 60 times a second.
    private func skyPreviewChanged() {
        guard skyPreview != nil else {
            previewWorker?.cancel()
            previewWorker = nil
            previewDirty = false
            previewScene = nil
            previewSummary = nil
            return
        }
        previewDirty = true
        guard previewWorker == nil else { return }
        previewWorker = Task { [weak self] in
            while let self, !Task.isCancelled, await self.applyLatestPreview() {
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { self?.previewWorker = nil }
        }
    }

    /// Computes and applies the newest requested preview. Returns false when there is nothing left to do.
    private func applyLatestPreview() async -> Bool {
        guard previewDirty, let date = skyPreview else { return false }
        previewDirty = false
        let (scene, summary) = await sky.snapshot(at: date)
        guard let current = skyPreview else { return false }  // returned to live meanwhile
        if current == date {
            previewScene = scene
            previewSummary = summary
            Perf.count("applied")
        }
        return true
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
        if topic == .sky {
            await refreshSky()
            return
        }
        if topic == .link || topic == .phone {
            await refreshLink()
            return
        }
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
            calendarRevision += 1
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

    func report(_ error: any Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
