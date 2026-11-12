import ApnumCore
import Foundation
import Synchronization
@testable import ApnumCalendar

/// In-memory backend. Never touches EventKit.
final class FakeCalendarBackend: CalendarBackend {
    struct State {
        var eventAccess: AccessState = .granted
        var reminderAccess: AccessState = .granted
        var calendars = [
            CalendarInfo(id: "cal-home", title: "Home", colorHex: "#FF3B30", sourceTitle: "iCloud", allowsModifications: true),
            CalendarInfo(id: "cal-work", title: "Work", colorHex: "#007AFF", sourceTitle: "Google", allowsModifications: true),
        ]
        var lists = [
            ReminderList(id: "list-inbox", title: "Inbox", colorHex: "#FF9500"),
            ReminderList(id: "list-shop", title: "Shopping", colorHex: "#34C759"),
        ]
        var events: [CalendarEvent] = []
        var reminders: [Reminder] = []
        var next = 1
        var lastRangeQuery: (Date, Date)?
        var continuation: AsyncStream<Void>.Continuation?
    }

    let state = Mutex(State())

    func with<T>(_ body: (inout sending State) throws -> sending T) rethrows -> sending T { try state.withLock(body) }

    func eventAccess() async -> AccessState { with { $0.eventAccess } }
    func reminderAccess() async -> AccessState { with { $0.reminderAccess } }
    func requestEventAccess() async throws -> AccessState {
        with { if $0.eventAccess == .notDetermined { $0.eventAccess = .granted }; return $0.eventAccess }
    }
    func requestReminderAccess() async throws -> AccessState {
        with { if $0.reminderAccess == .notDetermined { $0.reminderAccess = .granted }; return $0.reminderAccess }
    }

    func calendars() async throws -> [CalendarInfo] { with { $0.calendars } }

    func events(from: Date, to: Date, calendarIDs: [String]?) async throws -> [CalendarEvent] {
        with { s in
            s.lastRangeQuery = (from, to)
            return s.events.filter { e in
                e.start < to && e.end > from && (calendarIDs?.contains(e.calendarID) ?? true)
            }
        }
    }

    func event(id: String) async throws -> CalendarEvent? { with { s in s.events.first { $0.id == id } } }

    func createEvent(_ d: EventDraft) async throws -> CalendarEvent {
        try with { s in
            let calID = d.calendarID ?? "cal-home"
            guard let cal = s.calendars.first(where: { $0.id == calID }) else { throw ToolError.notFound("calendar \(calID)") }
            let e = CalendarEvent(
                id: "ev-\(s.next)", calendarID: cal.id, calendarTitle: cal.title, colorHex: cal.colorHex,
                title: d.title, start: d.start, end: d.end, isAllDay: d.isAllDay, location: d.location, notes: d.notes)
            s.next += 1
            s.events.append(e)
            return e
        }
    }

    func updateEvent(id: String, patch p: EventPatch) async throws -> CalendarEvent {
        try with { s in
            guard let i = s.events.firstIndex(where: { $0.id == id }) else { throw ToolError.notFound("event \(id)") }
            if let v = p.title { s.events[i].title = v }
            if let v = p.start { s.events[i].start = v }
            if let v = p.end { s.events[i].end = v }
            if let v = p.isAllDay { s.events[i].isAllDay = v }
            if let v = p.location { s.events[i].location = v.isEmpty ? nil : v }
            if let v = p.notes { s.events[i].notes = v.isEmpty ? nil : v }
            if let v = p.calendarID, let cal = s.calendars.first(where: { $0.id == v }) {
                s.events[i].calendarID = cal.id
                s.events[i].calendarTitle = cal.title
            }
            return s.events[i]
        }
    }

    func deleteEvent(id: String) async throws { with { s in s.events.removeAll { $0.id == id } } }

    func reminderLists() async throws -> [ReminderList] { with { $0.lists } }

    func reminders(listID: String?, includeCompleted: Bool) async throws -> [Reminder] {
        with { s in
            s.reminders.filter { (listID == nil || $0.listID == listID) && (includeCompleted || !$0.isCompleted) }
        }
    }

    func reminder(id: String) async throws -> Reminder? { with { s in s.reminders.first { $0.id == id } } }

    func createReminder(_ d: ReminderDraft) async throws -> Reminder {
        try with { s in
            let listID = d.listID ?? "list-inbox"
            guard let list = s.lists.first(where: { $0.id == listID }) else { throw ToolError.notFound("reminder list \(listID)") }
            let r = Reminder(
                id: "rem-\(s.next)", listID: list.id, listTitle: list.title, title: d.title, notes: d.notes,
                dueDate: d.dueDate, priority: d.priority)
            s.next += 1
            s.reminders.append(r)
            return r
        }
    }

    func updateReminder(id: String, patch p: ReminderPatch) async throws -> Reminder {
        try with { s in
            guard let i = s.reminders.firstIndex(where: { $0.id == id }) else { throw ToolError.notFound("reminder \(id)") }
            if let v = p.title { s.reminders[i].title = v }
            if let v = p.notes { s.reminders[i].notes = v.isEmpty ? nil : v }
            if p.clearDueDate { s.reminders[i].dueDate = nil }
            if let v = p.dueDate { s.reminders[i].dueDate = v }
            if let v = p.priority { s.reminders[i].priority = v }
            return s.reminders[i]
        }
    }

    func setReminderCompleted(id: String, completed: Bool) async throws -> Reminder {
        try with { s in
            guard let i = s.reminders.firstIndex(where: { $0.id == id }) else { throw ToolError.notFound("reminder \(id)") }
            s.reminders[i].isCompleted = completed
            s.reminders[i].completionDate = completed ? Date(timeIntervalSince1970: 1_000) : nil
            return s.reminders[i]
        }
    }

    func deleteReminder(id: String) async throws { with { s in s.reminders.removeAll { $0.id == id } } }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        with { $0.continuation = continuation }
        return stream
    }

    /// Simulates an external change (another app edited Calendar).
    func emitChange() { with { $0.continuation }?.yield() }
}
