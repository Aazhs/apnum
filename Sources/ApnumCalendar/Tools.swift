import ApnumCore
import Foundation

/// ISO-8601 parsing for tool inputs. Accepts "2026-11-12T09:00:00Z", offsets, fractional seconds,
/// local times without a zone ("2026-11-12T09:00:00") and plain dates ("2026-11-12", local midnight).
enum WireDate {
    static func parse(_ text: String, field: String, calendar: Calendar = .current) throws -> Date {
        let s = text.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
        ] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        let local = ISO8601DateFormatter()
        local.timeZone = calendar.timeZone
        local.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        if let d = local.date(from: s) { return d }
        local.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let d = local.date(from: s) { return d }
        throw ToolError.invalidInput(
            "\(field) \"\(text)\" is not a valid ISO-8601 date. Use e.g. 2026-11-12T09:30:00+01:00 or 2026-11-12")
    }
}

struct EventList: Codable, Sendable, Equatable {
    var count: Int
    var events: [CalendarEvent]
    var note: String?
}

struct CalendarList: Codable, Sendable, Equatable { var calendars: [CalendarInfo] }
struct ReminderListsOutput: Codable, Sendable, Equatable { var lists: [ReminderList] }
struct ReminderItems: Codable, Sendable, Equatable { var count: Int; var reminders: [Reminder] }

private let dateHint = "ISO-8601 date-time, e.g. 2026-11-12T09:30:00+01:00 (a plain date 2026-11-12 means local midnight)"

struct CalendarsTool: Tool {
    let service: CalendarService
    static let name = "calendar.calendars"
    static let summary = "List the calendars in Apple Calendar (id, title, color, account) that events can be read from or created in."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> CalendarList {
        CalendarList(calendars: try await service.calendars())
    }
}

struct EventsTool: Tool {
    struct Input: Decodable, Sendable {
        var start: String?
        var end: String?
        var calendarIDs: [String]?
    }
    let service: CalendarService
    static let name = "calendar.events"
    static let summary = "List Apple Calendar events between start and end (default: today 00:00 through the next 7 days, at most 366 days), sorted by start time."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.object([
        "start": .string("Range start, \(dateHint). Default: start of today.", format: "date-time"),
        "end": .string("Range end, \(dateHint). Default: start + 7 days. Ranges are capped at 366 days.", format: "date-time"),
        "calendarIDs": .array(of: .string(), description: "Only events from these calendar ids (see calendar.calendars)."),
    ])

    func run(_ input: Input, context: ToolContext) async throws -> EventList {
        let cal = Calendar.current
        let start = try input.start.map { try WireDate.parse($0, field: "start") } ?? cal.startOfDay(for: Date())
        var end = try input.end.map { try WireDate.parse($0, field: "end") }
            ?? cal.date(byAdding: .day, value: 7, to: start)!
        guard end > start else { throw ToolError.invalidInput("end must be after start") }
        var note: String?
        let limit = cal.date(byAdding: .day, value: 366, to: start)!
        if end > limit {
            end = limit
            note = "Range capped at 366 days; events after \(ISO8601DateFormatter().string(from: limit)) not included."
        }
        let events = try await service.events(from: start, to: end, calendarIDs: input.calendarIDs)
        return EventList(count: events.count, events: events, note: note)
    }
}

struct EventCreateTool: Tool {
    struct Input: Decodable, Sendable {
        var title: String
        var start: String
        var end: String?
        var durationMinutes: Int?
        var isAllDay: Bool?
        var location: String?
        var notes: String?
        var calendarID: String?
    }
    let service: CalendarService
    static let name = "calendar.event.create"
    static let summary = "Create an Apple Calendar event. Give end or durationMinutes (default 60 minutes; all-day events default to that day)."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "title": .string("Event title."),
        "start": .string("Start, \(dateHint).", format: "date-time"),
        "end": .string("End, \(dateHint). Takes precedence over durationMinutes.", format: "date-time"),
        "durationMinutes": .integer("Length in minutes if end is not given.", minimum: 1),
        "isAllDay": .boolean("All-day event. Default false."),
        "location": .string("Location."),
        "notes": .string("Notes."),
        "calendarID": .string("Calendar id from calendar.calendars. Default: the user's default calendar."),
    ], required: ["title", "start"])

    func run(_ input: Input, context: ToolContext) async throws -> CalendarEvent {
        let cal = Calendar.current
        var start = try WireDate.parse(input.start, field: "start")
        let allDay = input.isAllDay ?? false
        var end: Date
        if let e = input.end {
            end = try WireDate.parse(e, field: "end")
        } else if let minutes = input.durationMinutes {
            guard minutes > 0 else { throw ToolError.invalidInput("durationMinutes must be positive") }
            end = start.addingTimeInterval(Double(minutes) * 60)
        } else if allDay {
            start = cal.startOfDay(for: start)
            end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        } else {
            end = start.addingTimeInterval(3600)
        }
        return try await service.createEvent(EventDraft(
            title: input.title, start: start, end: end, isAllDay: allDay,
            location: input.location, notes: input.notes, calendarID: input.calendarID))
    }
}

struct EventUpdateTool: Tool {
    struct Input: Decodable, Sendable {
        var id: String
        var title: String?
        var start: String?
        var end: String?
        var isAllDay: Bool?
        var location: String?
        var notes: String?
        var calendarID: String?
    }
    let service: CalendarService
    static let name = "calendar.event.update"
    static let summary = "Change fields of an existing Apple Calendar event by id; omitted fields stay as they are. For a recurring event only this occurrence changes."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "id": .string("Event id from calendar.events."),
        "title": .string("New title."),
        "start": .string("New start, \(dateHint).", format: "date-time"),
        "end": .string("New end, \(dateHint).", format: "date-time"),
        "isAllDay": .boolean("Change all-day status."),
        "location": .string("New location; empty string clears it."),
        "notes": .string("New notes; empty string clears them."),
        "calendarID": .string("Move to this calendar id."),
    ], required: ["id"])

    func run(_ input: Input, context: ToolContext) async throws -> CalendarEvent {
        try await service.updateEvent(id: input.id, patch: EventPatch(
            title: input.title,
            start: try input.start.map { try WireDate.parse($0, field: "start") },
            end: try input.end.map { try WireDate.parse($0, field: "end") },
            isAllDay: input.isAllDay, location: input.location, notes: input.notes, calendarID: input.calendarID))
    }
}

struct EventDeleteTool: Tool {
    struct Input: Decodable, Sendable { var id: String }
    let service: CalendarService
    static let name = "calendar.event.delete"
    static let summary = "Permanently delete an Apple Calendar event by id (only this occurrence if it recurs)."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.object(["id": .string("Event id from calendar.events.")], required: ["id"])
    func run(_ input: Input, context: ToolContext) async throws -> Ack {
        try await service.deleteEvent(id: input.id)
        return Ack(message: "Deleted event \(input.id)")
    }
}

struct ReminderListsTool: Tool {
    let service: CalendarService
    static let name = "reminders.lists"
    static let summary = "List the reminder lists in Apple Reminders (id, title, color)."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> ReminderListsOutput {
        ReminderListsOutput(lists: try await service.reminderLists())
    }
}

struct RemindersListTool: Tool {
    struct Input: Decodable, Sendable {
        var listID: String?
        var includeCompleted: Bool?
    }
    let service: CalendarService
    static let name = "reminders.list"
    static let summary = "List Apple Reminders, optionally from one list; completed ones are left out unless includeCompleted is true."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.object([
        "listID": .string("Only this list (id from reminders.lists). Default: all lists."),
        "includeCompleted": .boolean("Include completed reminders. Default false."),
    ])
    func run(_ input: Input, context: ToolContext) async throws -> ReminderItems {
        let items = try await service.reminders(listID: input.listID, includeCompleted: input.includeCompleted ?? false)
        return ReminderItems(count: items.count, reminders: items)
    }
}

struct ReminderCreateTool: Tool {
    struct Input: Decodable, Sendable {
        var title: String
        var notes: String?
        var dueDate: String?
        var priority: Int?
        var listID: String?
    }
    let service: CalendarService
    static let name = "reminders.create"
    static let summary = "Create a reminder in Apple Reminders, optionally with a due date, priority and list."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "title": .string("Reminder title."),
        "notes": .string("Notes."),
        "dueDate": .string("Due, \(dateHint).", format: "date-time"),
        "priority": .integer("0 none, 1 high, 5 medium, 9 low.", minimum: 0, maximum: 9),
        "listID": .string("List id from reminders.lists. Default: the user's default list."),
    ], required: ["title"])
    func run(_ input: Input, context: ToolContext) async throws -> Reminder {
        try await service.createReminder(ReminderDraft(
            title: input.title, notes: input.notes,
            dueDate: try input.dueDate.map { try WireDate.parse($0, field: "dueDate") },
            priority: input.priority ?? 0, listID: input.listID))
    }
}

struct ReminderUpdateTool: Tool {
    struct Input: Decodable, Sendable {
        var id: String
        var title: String?
        var notes: String?
        var dueDate: String?
        var clearDueDate: Bool?
        var priority: Int?
        var listID: String?
    }
    let service: CalendarService
    static let name = "reminders.update"
    static let summary = "Change fields of an existing reminder by id; omitted fields stay as they are."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "id": .string("Reminder id from reminders.list."),
        "title": .string("New title."),
        "notes": .string("New notes; empty string clears them."),
        "dueDate": .string("New due date, \(dateHint).", format: "date-time"),
        "clearDueDate": .boolean("Remove the due date."),
        "priority": .integer("0 none, 1 high, 5 medium, 9 low.", minimum: 0, maximum: 9),
        "listID": .string("Move to this list id."),
    ], required: ["id"])
    func run(_ input: Input, context: ToolContext) async throws -> Reminder {
        try await service.updateReminder(id: input.id, patch: ReminderPatch(
            title: input.title, notes: input.notes,
            dueDate: try input.dueDate.map { try WireDate.parse($0, field: "dueDate") },
            clearDueDate: input.clearDueDate ?? false, priority: input.priority, listID: input.listID))
    }
}

struct ReminderCompleteTool: Tool {
    struct Input: Decodable, Sendable {
        var id: String
        var completed: Bool?
    }
    let service: CalendarService
    static let name = "reminders.complete"
    static let summary = "Mark a reminder completed (or, with completed=false, not completed) by id."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "id": .string("Reminder id from reminders.list."),
        "completed": .boolean("Default true; false reopens the reminder."),
    ], required: ["id"])
    func run(_ input: Input, context: ToolContext) async throws -> Reminder {
        try await service.setReminderCompleted(id: input.id, completed: input.completed ?? true)
    }
}

struct ReminderDeleteTool: Tool {
    struct Input: Decodable, Sendable { var id: String }
    let service: CalendarService
    static let name = "reminders.delete"
    static let summary = "Permanently delete a reminder by id."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.object(["id": .string("Reminder id from reminders.list.")], required: ["id"])
    func run(_ input: Input, context: ToolContext) async throws -> Ack {
        try await service.deleteReminder(id: input.id)
        return Ack(message: "Deleted reminder \(input.id)")
    }
}
