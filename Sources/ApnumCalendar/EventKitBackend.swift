import ApnumCore
import EventKit
import Foundation

/// The real backend. All EventKit objects stay inside this actor; only plain models leave it.
public actor EventKitBackend: CalendarBackend {
    private let store = EKEventStore()

    public init() {}

    // MARK: Access

    private static func state(_ status: EKAuthorizationStatus) -> AccessState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    public func eventAccess() -> AccessState { Self.state(EKEventStore.authorizationStatus(for: .event)) }
    public func reminderAccess() -> AccessState { Self.state(EKEventStore.authorizationStatus(for: .reminder)) }

    public func requestEventAccess() async throws -> AccessState {
        _ = try await store.requestFullAccessToEvents()
        return eventAccess()
    }

    public func requestReminderAccess() async throws -> AccessState {
        _ = try await store.requestFullAccessToReminders()
        return reminderAccess()
    }

    // MARK: Mapping

    private static func hex(_ color: CGColor?) -> String {
        guard let color,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              c.count >= 3
        else { return "#808080" }
        return ColorHex.string(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
    }

    private static func info(_ c: EKCalendar) -> CalendarInfo {
        CalendarInfo(
            id: c.calendarIdentifier, title: c.title, colorHex: hex(c.cgColor),
            sourceTitle: c.source?.title ?? "", allowsModifications: c.allowsContentModifications)
    }

    private static func model(_ e: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: e.eventIdentifier ?? e.calendarItemIdentifier, calendarID: e.calendar?.calendarIdentifier ?? "",
            calendarTitle: e.calendar?.title ?? "", colorHex: hex(e.calendar?.cgColor), title: e.title ?? "",
            start: e.startDate, end: e.endDate, isAllDay: e.isAllDay, location: nonEmpty(e.location),
            notes: nonEmpty(e.notes), url: e.url?.absoluteString)
    }

    private static func model(_ r: EKReminder) -> Reminder {
        var due: Date?
        if var comps = r.dueDateComponents {
            if comps.calendar == nil { comps.calendar = .current }
            due = comps.date
        }
        return Reminder(
            id: r.calendarItemIdentifier, listID: r.calendar?.calendarIdentifier ?? "",
            listTitle: r.calendar?.title ?? "", title: r.title ?? "", notes: nonEmpty(r.notes), dueDate: due,
            isCompleted: r.isCompleted, completionDate: r.completionDate, priority: min(max(r.priority, 0), 9))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func components(_ date: Date) -> DateComponents {
        var c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.calendar = .current
        return c
    }

    private func eventCalendar(_ id: String) throws -> EKCalendar {
        guard let c = store.calendar(withIdentifier: id), c.allowedEntityTypes.contains(.event) else {
            throw ToolError.notFound("calendar \(id)")
        }
        guard c.allowsContentModifications else { throw ToolError.invalidInput("calendar \"\(c.title)\" is read-only") }
        return c
    }

    private func reminderCalendar(_ id: String) throws -> EKCalendar {
        guard let c = store.calendar(withIdentifier: id), c.allowedEntityTypes.contains(.reminder) else {
            throw ToolError.notFound("reminder list \(id)")
        }
        guard c.allowsContentModifications else { throw ToolError.invalidInput("list \"\(c.title)\" is read-only") }
        return c
    }

    private func ekEvent(_ id: String) throws -> EKEvent {
        guard let e = store.event(withIdentifier: id) else { throw ToolError.notFound("event \(id)") }
        return e
    }

    private func ekReminder(_ id: String) throws -> EKReminder {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolError.notFound("reminder \(id)")
        }
        return r
    }

    // MARK: Events

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map(Self.info)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func events(from: Date, to: Date, calendarIDs: [String]?) -> [CalendarEvent] {
        var cals: [EKCalendar]?
        if let calendarIDs {
            cals = calendarIDs.compactMap { store.calendar(withIdentifier: $0) }
            if cals?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        return store.events(matching: predicate).map(Self.model).sorted { $0.start < $1.start }
    }

    public func event(id: String) -> CalendarEvent? { store.event(withIdentifier: id).map(Self.model) }

    public func createEvent(_ draft: EventDraft) throws -> CalendarEvent {
        let e = EKEvent(eventStore: store)
        if let id = draft.calendarID {
            e.calendar = try eventCalendar(id)
        } else if let def = store.defaultCalendarForNewEvents {
            e.calendar = def
        } else {
            throw ToolError.unavailable("No default calendar for new events. Add a calendar in the Calendar app.")
        }
        e.title = draft.title
        e.startDate = draft.start
        e.endDate = draft.end
        e.isAllDay = draft.isAllDay
        e.location = draft.location
        e.notes = draft.notes
        try store.save(e, span: .thisEvent, commit: true)
        return Self.model(e)
    }

    public func updateEvent(id: String, patch: EventPatch) throws -> CalendarEvent {
        let e = try ekEvent(id)
        if let v = patch.title { e.title = v }
        if let v = patch.start { e.startDate = v }
        if let v = patch.end { e.endDate = v }
        if let v = patch.isAllDay { e.isAllDay = v }
        if let v = patch.location { e.location = v.isEmpty ? nil : v }
        if let v = patch.notes { e.notes = v.isEmpty ? nil : v }
        if let v = patch.calendarID { e.calendar = try eventCalendar(v) }
        try store.save(e, span: .thisEvent, commit: true)
        return Self.model(e)
    }

    public func deleteEvent(id: String) throws {
        try store.remove(try ekEvent(id), span: .thisEvent, commit: true)
    }

    // MARK: Reminders

    public func reminderLists() -> [ReminderList] {
        store.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title, colorHex: Self.hex($0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func reminders(listID: String?, includeCompleted: Bool) async throws -> [Reminder] {
        var cals: [EKCalendar]?
        if let listID {
            guard let c = store.calendar(withIdentifier: listID), c.allowedEntityTypes.contains(.reminder) else {
                throw ToolError.notFound("reminder list \(listID)")
            }
            cals = [c]
        }
        let predicate = store.predicateForReminders(in: cals)
        let all: [Reminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: (result ?? []).map(Self.model))
            }
        }
        return all.filter { includeCompleted || !$0.isCompleted }
    }

    public func reminder(id: String) -> Reminder? {
        (store.calendarItem(withIdentifier: id) as? EKReminder).map(Self.model)
    }

    public func createReminder(_ draft: ReminderDraft) throws -> Reminder {
        let r = EKReminder(eventStore: store)
        if let id = draft.listID {
            r.calendar = try reminderCalendar(id)
        } else if let def = store.defaultCalendarForNewReminders() {
            r.calendar = def
        } else {
            throw ToolError.unavailable("No default list for new reminders. Add a list in the Reminders app.")
        }
        r.title = draft.title
        r.notes = draft.notes
        r.priority = draft.priority
        if let due = draft.dueDate { r.dueDateComponents = Self.components(due) }
        try store.save(r, commit: true)
        return Self.model(r)
    }

    public func updateReminder(id: String, patch: ReminderPatch) throws -> Reminder {
        let r = try ekReminder(id)
        if let v = patch.title { r.title = v }
        if let v = patch.notes { r.notes = v.isEmpty ? nil : v }
        if patch.clearDueDate { r.dueDateComponents = nil }
        if let v = patch.dueDate { r.dueDateComponents = Self.components(v) }
        if let v = patch.priority { r.priority = v }
        if let v = patch.listID { r.calendar = try reminderCalendar(v) }
        try store.save(r, commit: true)
        return Self.model(r)
    }

    public func setReminderCompleted(id: String, completed: Bool) throws -> Reminder {
        let r = try ekReminder(id)
        r.isCompleted = completed
        try store.save(r, commit: true)
        return Self.model(r)
    }

    public func deleteReminder(id: String) throws {
        try store.remove(try ekReminder(id), commit: true)
    }

    // MARK: Changes

    public nonisolated func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged).map({ _ in () }) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
