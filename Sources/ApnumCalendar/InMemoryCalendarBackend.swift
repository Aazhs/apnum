import ApnumCore
import Foundation
import Synchronization


/// In-memory backend used for demo mode (APNUM_DEMO=1) and screenshots. Never touches EventKit.
public final class InMemoryCalendarBackend: CalendarBackend {
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

    public init() {}

    func with<T>(_ body: (inout sending State) throws -> sending T) rethrows -> sending T { try state.withLock(body) }

    public func eventAccess() async -> AccessState { with { $0.eventAccess } }
    public func reminderAccess() async -> AccessState { with { $0.reminderAccess } }
    public func requestEventAccess() async throws -> AccessState {
        with { if $0.eventAccess == .notDetermined { $0.eventAccess = .granted }; return $0.eventAccess }
    }
    public func requestReminderAccess() async throws -> AccessState {
        with { if $0.reminderAccess == .notDetermined { $0.reminderAccess = .granted }; return $0.reminderAccess }
    }

    public func calendars() async throws -> [CalendarInfo] { with { $0.calendars } }

    public func events(from: Date, to: Date, calendarIDs: [String]?) async throws -> [CalendarEvent] {
        with { s in
            s.lastRangeQuery = (from, to)
            return s.events.filter { e in
                e.start < to && e.end > from && (calendarIDs?.contains(e.calendarID) ?? true)
            }
        }
    }

    public func event(id: String) async throws -> CalendarEvent? { with { s in s.events.first { $0.id == id } } }

    public func createEvent(_ d: EventDraft) async throws -> CalendarEvent {
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

    public func updateEvent(id: String, patch p: EventPatch) async throws -> CalendarEvent {
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

    public func deleteEvent(id: String) async throws { with { s in s.events.removeAll { $0.id == id } } }

    public func reminderLists() async throws -> [ReminderList] { with { $0.lists } }

    public func reminders(listID: String?, includeCompleted: Bool) async throws -> [Reminder] {
        with { s in
            s.reminders.filter { (listID == nil || $0.listID == listID) && (includeCompleted || !$0.isCompleted) }
        }
    }

    public func reminder(id: String) async throws -> Reminder? { with { s in s.reminders.first { $0.id == id } } }

    public func createReminder(_ d: ReminderDraft) async throws -> Reminder {
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

    public func updateReminder(id: String, patch p: ReminderPatch) async throws -> Reminder {
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

    public func setReminderCompleted(id: String, completed: Bool) async throws -> Reminder {
        try with { s in
            guard let i = s.reminders.firstIndex(where: { $0.id == id }) else { throw ToolError.notFound("reminder \(id)") }
            s.reminders[i].isCompleted = completed
            s.reminders[i].completionDate = completed ? Date(timeIntervalSince1970: 1_000) : nil
            return s.reminders[i]
        }
    }

    public func deleteReminder(id: String) async throws { with { s in s.reminders.removeAll { $0.id == id } } }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        with { $0.continuation = continuation }
        return stream
    }

    /// Simulates an external change (another app edited Calendar).
    public func emitChange() { with { $0.continuation }?.yield() }
}

public extension InMemoryCalendarBackend {
    /// A backend filled with a plausible week, for demo mode and screenshots.
    static func demo(now: Date = Date(), calendar: Calendar = .current) -> InMemoryCalendarBackend {
        let backend = InMemoryCalendarBackend()
        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: today)!
        }
        let home = ("cal-home", "Home", "#FF3B30"), work = ("cal-work", "Work", "#007AFF"), gym = ("cal-gym", "Fitness", "#34C759")
        let plan: [(Int, Int, Int, Int, (String, String, String), String, String?)] = [
            (0, 7, 0, 45, gym, "Morning run", "Riverside loop"),
            (0, 10, 0, 30, work, "Stand-up", nil),
            (0, 13, 30, 60, work, "Design review", "Studio 2"),
            (0, 17, 0, 90, home, "Groceries and errands", nil),
            (0, 20, 30, 120, home, "Dinner with Meera", "Olive Bistro"),
            (1, 9, 30, 60, work, "Sprint planning", nil),
            (1, 18, 0, 60, gym, "Climbing", "Boulder hall"),
            (2, 11, 0, 30, work, "Dentist", "Dr. Rao"),
            (3, 15, 0, 120, work, "Write release notes", nil),
            (4, 19, 0, 180, home, "Movie night", nil),
        ]
        backend.with { s in
            s.calendars.append(CalendarInfo(id: gym.0, title: gym.1, colorHex: gym.2, sourceTitle: "iCloud", allowsModifications: true))
            for (i, p) in plan.enumerated() {
                let start = at(p.0, p.1, p.2)
                s.events.append(CalendarEvent(
                    id: "demo-\(i)", calendarID: p.4.0, calendarTitle: p.4.1, colorHex: p.4.2, title: p.5,
                    start: start, end: start.addingTimeInterval(TimeInterval(p.3 * 60)), isAllDay: false, location: p.6))
            }
            s.events.append(CalendarEvent(
                id: "demo-allday", calendarID: home.0, calendarTitle: home.1, colorHex: home.2, title: "Aai's birthday",
                start: at(2, 0), end: at(3, 0), isAllDay: true))
            let reminders: [(String, String, String, Date?, Int)] = [
                ("list-inbox", "Inbox", "Renew passport", at(0, 18), 1),
                ("list-inbox", "Inbox", "Call the bank about the card", at(-1, 12), 0),
                ("list-shop", "Shopping", "Oat milk", nil, 0),
                ("list-shop", "Shopping", "Coffee beans", nil, 0),
                ("list-inbox", "Inbox", "Book flights for December", at(3, 10), 5),
            ]
            for (i, r) in reminders.enumerated() {
                s.reminders.append(Reminder(id: "demo-r\(i)", listID: r.0, listTitle: r.1, title: r.2, dueDate: r.3, priority: r.4))
            }
        }
        return backend
    }
}
