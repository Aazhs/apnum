import ApnumCore
import Foundation

/// Apple Calendar and Reminders through a `CalendarBackend` (EventKit in the app).
/// Writes publish `.calendar` / `.reminders`; backend store changes do too.
public actor CalendarService {
    private let backend: any CalendarBackend
    private let changes: ChangeFeed
    private var observer: Task<Void, Never>?

    public init(backend: any CalendarBackend, changes: ChangeFeed) {
        self.backend = backend
        self.changes = changes
    }

    public static func live(changes: ChangeFeed) -> CalendarService {
        CalendarService(backend: EventKitBackend(), changes: changes)
    }

    deinit { observer?.cancel() }

    /// Publishes `.calendar` and `.reminders` whenever the system store changes. Safe to call twice.
    public func startObservingChanges() {
        guard observer == nil else { return }
        let stream = backend.changes()
        let feed = changes
        observer = Task {
            for await _ in stream {
                feed.publish(.calendar)
                feed.publish(.reminders)
            }
        }
    }

    // MARK: Access

    public func eventAccess() async -> AccessState { await backend.eventAccess() }
    public func reminderAccess() async -> AccessState { await backend.reminderAccess() }

    public func requestEventAccess() async throws -> AccessState {
        let state = try await backend.requestEventAccess()
        changes.publish(.calendar)
        return state
    }

    public func requestReminderAccess() async throws -> AccessState {
        let state = try await backend.requestReminderAccess()
        changes.publish(.reminders)
        return state
    }

    private func requireEvents() async throws {
        guard await backend.eventAccess() == .granted else {
            throw ToolError.unavailable(
                "Calendar access not granted. Open apnum and allow access in System Settings › Privacy & Security › Calendars")
        }
    }

    private func requireReminders() async throws {
        guard await backend.reminderAccess() == .granted else {
            throw ToolError.unavailable(
                "Reminders access not granted. Open apnum and allow access in System Settings › Privacy & Security › Reminders")
        }
    }

    // MARK: Events

    public func calendars() async throws -> [CalendarInfo] {
        try await requireEvents()
        return try await backend.calendars()
    }

    public func events(from: Date, to: Date, calendarIDs: [String]? = nil) async throws -> [CalendarEvent] {
        try await requireEvents()
        guard to > from else { throw ToolError.invalidInput("end must be after start") }
        return try await backend.events(from: from, to: to, calendarIDs: calendarIDs).sorted { $0.start < $1.start }
    }

    /// Events overlapping the calendar day containing `now`.
    public func todayAgenda(now: Date, calendar: Calendar = .current) async throws -> [CalendarEvent] {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return try await events(from: start, to: end)
    }

    public func event(id: String) async throws -> CalendarEvent {
        try await requireEvents()
        guard let e = try await backend.event(id: id) else { throw ToolError.notFound("event \(id)") }
        return e
    }

    @discardableResult
    public func createEvent(_ draft: EventDraft) async throws -> CalendarEvent {
        try await requireEvents()
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.invalidInput("title must not be empty")
        }
        guard draft.end > draft.start else { throw ToolError.invalidInput("end must be after start") }
        let created = try await backend.createEvent(draft)
        changes.publish(.calendar)
        return created
    }

    @discardableResult
    public func updateEvent(id: String, patch: EventPatch) async throws -> CalendarEvent {
        let existing = try await event(id: id)
        if let t = patch.title, t.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ToolError.invalidInput("title must not be empty")
        }
        let start = patch.start ?? existing.start
        let end = patch.end ?? existing.end
        guard end > start else { throw ToolError.invalidInput("end must be after start") }
        let updated = try await backend.updateEvent(id: id, patch: patch)
        changes.publish(.calendar)
        return updated
    }

    public func deleteEvent(id: String) async throws {
        _ = try await event(id: id)
        try await backend.deleteEvent(id: id)
        changes.publish(.calendar)
    }

    // MARK: Reminders

    public func reminderLists() async throws -> [ReminderList] {
        try await requireReminders()
        return try await backend.reminderLists()
    }

    public func reminders(listID: String? = nil, includeCompleted: Bool = false) async throws -> [Reminder] {
        try await requireReminders()
        return try await backend.reminders(listID: listID, includeCompleted: includeCompleted)
    }

    public func reminder(id: String) async throws -> Reminder {
        try await requireReminders()
        guard let r = try await backend.reminder(id: id) else { throw ToolError.notFound("reminder \(id)") }
        return r
    }

    @discardableResult
    public func createReminder(_ draft: ReminderDraft) async throws -> Reminder {
        try await requireReminders()
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.invalidInput("title must not be empty")
        }
        try Self.checkPriority(draft.priority)
        let created = try await backend.createReminder(draft)
        changes.publish(.reminders)
        return created
    }

    @discardableResult
    public func updateReminder(id: String, patch: ReminderPatch) async throws -> Reminder {
        _ = try await reminder(id: id)
        if let t = patch.title, t.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ToolError.invalidInput("title must not be empty")
        }
        if let p = patch.priority { try Self.checkPriority(p) }
        if patch.clearDueDate && patch.dueDate != nil {
            throw ToolError.invalidInput("dueDate and clearDueDate cannot both be set")
        }
        let updated = try await backend.updateReminder(id: id, patch: patch)
        changes.publish(.reminders)
        return updated
    }

    @discardableResult
    public func setReminderCompleted(id: String, completed: Bool = true) async throws -> Reminder {
        _ = try await reminder(id: id)
        let updated = try await backend.setReminderCompleted(id: id, completed: completed)
        changes.publish(.reminders)
        return updated
    }

    public func deleteReminder(id: String) async throws {
        _ = try await reminder(id: id)
        try await backend.deleteReminder(id: id)
        changes.publish(.reminders)
    }

    private static func checkPriority(_ p: Int) throws {
        guard (0...9).contains(p) else { throw ToolError.invalidInput("priority must be 0 (none) or 1 (high) to 9 (low)") }
    }

    // MARK: Tools

    public nonisolated func makeTools() -> [AnyTool] {
        [
            AnyTool(CalendarsTool(service: self)),
            AnyTool(EventsTool(service: self)),
            AnyTool(EventCreateTool(service: self)),
            AnyTool(EventUpdateTool(service: self)),
            AnyTool(EventDeleteTool(service: self)),
            AnyTool(ReminderListsTool(service: self)),
            AnyTool(RemindersListTool(service: self)),
            AnyTool(ReminderCreateTool(service: self)),
            AnyTool(ReminderUpdateTool(service: self)),
            AnyTool(ReminderCompleteTool(service: self)),
            AnyTool(ReminderDeleteTool(service: self)),
        ]
    }
}
