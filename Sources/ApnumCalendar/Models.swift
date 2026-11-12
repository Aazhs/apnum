import Foundation

/// Authorization for one EventKit entity type (events or reminders).
public enum AccessState: String, Codable, Sendable, Equatable {
    case notDetermined, denied, restricted, granted, writeOnly
}

public struct CalendarInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var colorHex: String
    public var sourceTitle: String
    public var allowsModifications: Bool

    public init(id: String, title: String, colorHex: String, sourceTitle: String, allowsModifications: Bool) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.sourceTitle = sourceTitle
        self.allowsModifications = allowsModifications
    }
}

public struct CalendarEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var calendarID: String
    public var calendarTitle: String
    public var colorHex: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var url: String?

    public init(
        id: String, calendarID: String, calendarTitle: String, colorHex: String, title: String,
        start: Date, end: Date, isAllDay: Bool, location: String? = nil, notes: String? = nil, url: String? = nil
    ) {
        self.id = id
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.colorHex = colorHex
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
    }
}

public struct ReminderList: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var colorHex: String

    public init(id: String, title: String, colorHex: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
    }
}

public struct Reminder: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var listID: String
    public var listTitle: String
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var isCompleted: Bool
    public var completionDate: Date?
    /// 0 none, 1 high ... 9 low (EventKit's values).
    public var priority: Int

    public init(
        id: String, listID: String, listTitle: String, title: String, notes: String? = nil,
        dueDate: Date? = nil, isCompleted: Bool = false, completionDate: Date? = nil, priority: Int = 0
    ) {
        self.id = id
        self.listID = listID
        self.listTitle = listTitle
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.priority = priority
    }
}

// MARK: - Backend requests

/// A new event. `calendarID == nil` means the default calendar for new events.
public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var calendarID: String?

    public init(
        title: String, start: Date, end: Date, isAllDay: Bool = false,
        location: String? = nil, notes: String? = nil, calendarID: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendarID = calendarID
    }
}

/// Changes to an event. `nil` leaves a field alone; for `location` and `notes` an empty string clears it.
public struct EventPatch: Sendable, Equatable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool?
    public var location: String?
    public var notes: String?
    public var calendarID: String?

    public init(
        title: String? = nil, start: Date? = nil, end: Date? = nil, isAllDay: Bool? = nil,
        location: String? = nil, notes: String? = nil, calendarID: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendarID = calendarID
    }
}

/// A new reminder. `listID == nil` means the default list for new reminders.
public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var priority: Int
    public var listID: String?

    public init(title: String, notes: String? = nil, dueDate: Date? = nil, priority: Int = 0, listID: String? = nil) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.priority = priority
        self.listID = listID
    }
}

/// Changes to a reminder. `nil` leaves a field alone; an empty `notes` clears it; `clearDueDate` removes the due date.
public struct ReminderPatch: Sendable, Equatable {
    public var title: String?
    public var notes: String?
    public var dueDate: Date?
    public var clearDueDate: Bool
    public var priority: Int?
    public var listID: String?

    public init(
        title: String? = nil, notes: String? = nil, dueDate: Date? = nil, clearDueDate: Bool = false,
        priority: Int? = nil, listID: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.clearDueDate = clearDueDate
        self.priority = priority
        self.listID = listID
    }
}

// MARK: - Helpers

public enum ColorHex {
    /// "#RRGGBB" from 0...1 components (values are clamped).
    public static func string(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

/// The backend a `CalendarService` talks to. `EventKitBackend` is the real one.
public protocol CalendarBackend: Sendable {
    func eventAccess() async -> AccessState
    func reminderAccess() async -> AccessState
    func requestEventAccess() async throws -> AccessState
    func requestReminderAccess() async throws -> AccessState

    func calendars() async throws -> [CalendarInfo]
    func events(from: Date, to: Date, calendarIDs: [String]?) async throws -> [CalendarEvent]
    func event(id: String) async throws -> CalendarEvent?
    func createEvent(_ draft: EventDraft) async throws -> CalendarEvent
    func updateEvent(id: String, patch: EventPatch) async throws -> CalendarEvent
    func deleteEvent(id: String) async throws

    func reminderLists() async throws -> [ReminderList]
    func reminders(listID: String?, includeCompleted: Bool) async throws -> [Reminder]
    func reminder(id: String) async throws -> Reminder?
    func createReminder(_ draft: ReminderDraft) async throws -> Reminder
    func updateReminder(id: String, patch: ReminderPatch) async throws -> Reminder
    func setReminderCompleted(id: String, completed: Bool) async throws -> Reminder
    func deleteReminder(id: String) async throws

    /// Yields whenever the underlying store changes.
    func changes() -> AsyncStream<Void>
}
