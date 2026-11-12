import ApnumCore
import Foundation
import Testing
@testable import ApnumCalendar

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)  // fixed instant

@Suite struct CalendarServiceTests {
    let fake = FakeCalendarBackend()
    let feed = ChangeFeed()
    let service: CalendarService

    init() { service = CalendarService(backend: fake, changes: feed) }

    func registry() -> ToolRegistry { ToolRegistry(tools: service.makeTools()) }

    // MARK: access

    @Test func deniedEventsThrowUnavailable() async {
        fake.with { $0.eventAccess = .denied }
        await #expect(throws: ToolError.unavailable(
            "Calendar access not granted. Open apnum and allow access in System Settings › Privacy & Security › Calendars")
        ) { _ = try await service.calendars() }
        await #expect(throws: ToolError.self) { _ = try await service.todayAgenda(now: t0) }
    }

    @Test func writeOnlyCountsAsNotGranted() async {
        fake.with { $0.reminderAccess = .writeOnly }
        await #expect(throws: ToolError.self) { _ = try await service.reminders() }
        await #expect(throws: ToolError.self) {
            _ = try await service.createReminder(ReminderDraft(title: "x"))
        }
    }

    @Test func requestAccess() async throws {
        fake.with { $0.eventAccess = .notDetermined }
        #expect(await service.eventAccess() == .notDetermined)
        #expect(try await service.requestEventAccess() == .granted)
        #expect(try await service.requestReminderAccess() == .granted)
    }

    // MARK: events

    @Test func eventsRangeValidation() async {
        await #expect(throws: ToolError.invalidInput("end must be after start")) {
            _ = try await service.events(from: t0, to: t0)
        }
    }

    @Test func todayAgendaCoversTheDay() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
        let morning = noon.addingTimeInterval(-3 * 3600)
        let tomorrow = noon.addingTimeInterval(24 * 3600)
        try await service.createEvent(EventDraft(title: "Standup", start: morning, end: morning.addingTimeInterval(1800)))
        try await service.createEvent(EventDraft(title: "Later", start: tomorrow, end: tomorrow.addingTimeInterval(1800)))
        let agenda = try await service.todayAgenda(now: noon, calendar: cal)
        #expect(agenda.map(\.title) == ["Standup"])
        let range = fake.with { $0.lastRangeQuery }
        #expect(range?.0 == cal.startOfDay(for: noon))
        #expect(range?.1 == cal.startOfDay(for: noon).addingTimeInterval(86_400))
    }

    @Test func createUpdateDeleteEvent() async throws {
        let created = try await service.createEvent(EventDraft(
            title: "Lunch", start: t0, end: t0.addingTimeInterval(3600), location: "Cafe"))
        #expect(created.calendarTitle == "Home")
        let updated = try await service.updateEvent(id: created.id, patch: EventPatch(title: "Brunch", location: ""))
        #expect(updated.title == "Brunch")
        #expect(updated.location == nil)
        await #expect(throws: ToolError.invalidInput("end must be after start")) {
            _ = try await service.updateEvent(id: created.id, patch: EventPatch(start: t0.addingTimeInterval(7200)))
        }
        try await service.deleteEvent(id: created.id)
        await #expect(throws: ToolError.notFound("event \(created.id)")) { try await service.deleteEvent(id: created.id) }
        await #expect(throws: ToolError.self) {
            _ = try await service.createEvent(EventDraft(title: "  ", start: t0, end: t0.addingTimeInterval(60)))
        }
    }

    // MARK: reminders

    @Test func reminderFilterAndComplete() async throws {
        let a = try await service.createReminder(ReminderDraft(title: "Milk", priority: 1, listID: "list-shop"))
        let b = try await service.createReminder(ReminderDraft(title: "Call mum"))
        #expect(try await service.reminders().count == 2)
        #expect(try await service.reminders(listID: "list-shop").map(\.id) == [a.id])
        let done = try await service.setReminderCompleted(id: b.id)
        #expect(done.isCompleted)
        #expect(try await service.reminders().map(\.id) == [a.id])
        #expect(try await service.reminders(includeCompleted: true).count == 2)
        let reopened = try await service.setReminderCompleted(id: b.id, completed: false)
        #expect(!reopened.isCompleted)
        let upd = try await service.updateReminder(id: a.id, patch: ReminderPatch(notes: "2 litres", dueDate: t0))
        #expect(upd.notes == "2 litres" && upd.dueDate == t0)
        #expect(try await service.updateReminder(id: a.id, patch: ReminderPatch(clearDueDate: true)).dueDate == nil)
        await #expect(throws: ToolError.self) { _ = try await service.createReminder(ReminderDraft(title: "x", priority: 12)) }
        try await service.deleteReminder(id: a.id)
        await #expect(throws: ToolError.notFound("reminder \(a.id)")) { _ = try await service.setReminderCompleted(id: a.id) }
    }

    // MARK: change feed

    private func collect(_ n: Int, from stream: AsyncStream<ChangeTopic>) async -> [ChangeTopic] {
        var out: [ChangeTopic] = []
        for await topic in stream {
            out.append(topic)
            if out.count == n { break }
        }
        return out
    }

    @Test func writesPublishTopics() async throws {
        let stream = feed.subscribe()
        let e = try await service.createEvent(EventDraft(title: "A", start: t0, end: t0.addingTimeInterval(60)))
        try await service.deleteEvent(id: e.id)
        let r = try await service.createReminder(ReminderDraft(title: "R"))
        try await service.setReminderCompleted(id: r.id)
        #expect(await collect(4, from: stream) == [.calendar, .calendar, .reminders, .reminders])
    }

    @Test func backendChangesPublishBothTopics() async {
        let stream = feed.subscribe()
        await service.startObservingChanges()
        await service.startObservingChanges()  // idempotent
        fake.emitChange()
        #expect(await collect(2, from: stream) == [.calendar, .reminders])
    }

    // MARK: tools

    @Test func toolNamesAndTiers() {
        let d = Dictionary(uniqueKeysWithValues: registry().descriptors.map { ($0.name, $0.tier) })
        #expect(d == [
            "calendar.calendars": .read, "calendar.events": .read, "calendar.event.create": .write,
            "calendar.event.update": .write, "calendar.event.delete": .dangerous,
            "reminders.lists": .read, "reminders.list": .read, "reminders.create": .write,
            "reminders.update": .write, "reminders.complete": .write, "reminders.delete": .dangerous,
        ])
    }

    @Test func createEventWithDurationRoundTrip() async throws {
        let out = try await registry().callJSON("calendar.event.create", input: [
            "title": "Dentist", "start": "2026-11-12T09:00:00Z", "durationMinutes": 45, "location": "Main St",
        ], caller: .ui)
        #expect(out["title"] == "Dentist")
        let event = try out.decode(CalendarEvent.self)
        #expect(event.end.timeIntervalSince(event.start) == 45 * 60)

        let listed = try await registry().callJSON("calendar.events", input: [
            "start": "2026-11-12T00:00:00Z", "end": "2026-11-13T00:00:00Z",
        ], caller: .agent("claude-code"))
        #expect(listed["count"] == 1)

        _ = try await registry().callJSON("calendar.event.update", input: ["id": .string(event.id), "title": "Dentist 2"], caller: .ui)
        #expect(fake.with { $0.events.first?.title } == "Dentist 2")
        _ = try await registry().callJSON("calendar.event.delete", input: ["id": .string(event.id)], caller: .ui)
        #expect(fake.with { $0.events.isEmpty })
    }

    @Test func eventsDefaultsAndCap() async throws {
        _ = try await registry().callJSON("calendar.events", caller: .ui)
        let r1 = try #require(fake.with { $0.lastRangeQuery })
        #expect(r1.0 == Calendar.current.startOfDay(for: Date()))
        #expect(Calendar.current.dateComponents([.day], from: r1.0, to: r1.1).day == 7)

        let out = try await registry().callJSON("calendar.events", input: [
            "start": "2026-01-01T00:00:00Z", "end": "2030-01-01T00:00:00Z",
        ], caller: .ui)
        let r2 = try #require(fake.with { $0.lastRangeQuery })
        #expect(Calendar.current.dateComponents([.day], from: r2.0, to: r2.1).day == 366)
        #expect(out["note"] != nil)
    }

    @Test func invalidDatesAreRejected() async throws {
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("calendar.events", input: ["start": "next tuesday"], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("calendar.events", input: ["start": "2026-11-12", "end": "2026-11-10"], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("calendar.event.create", input: [
                "title": "x", "start": "2026-11-12T10:00:00Z", "end": "2026-11-12T09:00:00Z",
            ], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("reminders.create", input: ["title": "x", "dueDate": "soon"], caller: .ui)
        }
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("calendar.event.create", input: ["title": "x"], caller: .ui)
        }
        await #expect(throws: ToolError.notFound("event nope")) {
            _ = try await registry().callJSON("calendar.event.update", input: ["id": "nope"], caller: .ui)
        }
    }

    @Test func dateFormatsAccepted() throws {
        let z = try WireDate.parse("2026-11-12T09:00:00Z", field: "f")
        #expect(try WireDate.parse("2026-11-12T10:00:00+01:00", field: "f") == z)
        #expect(try WireDate.parse("2026-11-12T09:00:00.500Z", field: "f") == z.addingTimeInterval(0.5))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(try WireDate.parse("2026-11-12T09:00:00", field: "f", calendar: cal) == z)
        #expect(try WireDate.parse("2026-11-12", field: "f", calendar: cal) == z.addingTimeInterval(-9 * 3600))
    }

    @Test func reminderToolsRoundTrip() async throws {
        let reg = registry()
        let created = try await reg.callJSON("reminders.create", input: [
            "title": "Pay rent", "dueDate": "2026-12-01T09:00:00Z", "priority": 1, "listID": "list-shop",
        ], caller: .cli)
        let id = try #require(created["id"])
        #expect(created["listTitle"] == "Shopping")
        #expect(try await reg.callJSON("reminders.list", caller: .ui)["count"] == 1)
        _ = try await reg.callJSON("reminders.complete", input: ["id": id], caller: .ui)
        #expect(try await reg.callJSON("reminders.list", caller: .ui)["count"] == 0)
        #expect(try await reg.callJSON("reminders.list", input: ["includeCompleted": true], caller: .ui)["count"] == 1)
        _ = try await reg.callJSON("reminders.complete", input: ["id": id, "completed": false], caller: .ui)
        _ = try await reg.callJSON("reminders.update", input: ["id": id, "clearDueDate": true, "notes": "done soon"], caller: .ui)
        #expect(fake.with { $0.reminders.first?.dueDate } == nil)
        #expect(try await reg.callJSON("reminders.lists", caller: .ui)["lists"]?.decode([ReminderList].self).count == 2)
        #expect(try await reg.callJSON("calendar.calendars", caller: .ui)["calendars"]?.decode([CalendarInfo].self).count == 2)
        _ = try await reg.callJSON("reminders.delete", input: ["id": id], caller: .ui)
        #expect(fake.with { $0.reminders.isEmpty })
        await #expect(throws: ToolError.self) {
            _ = try await reg.callJSON("reminders.delete", input: ["id": id], caller: .agent("x"))
        }
    }

    @Test func deniedAccessSurfacesThroughTools() async {
        fake.with { $0.reminderAccess = .denied }
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("reminders.list", caller: .ui)
        }
    }

    @Test func schemasListEveryInputField() {
        let reg = registry()
        let create = reg.descriptor(named: "calendar.event.create")?.inputSchema
        #expect(create?["required"] == ["start", "title"])
        #expect(create?["properties"]?["durationMinutes"] != nil)
        #expect(reg.descriptor(named: "reminders.complete")?.inputSchema["properties"]?["completed"] != nil)
    }
}

@Suite struct ColorHexTests {
    @Test func hexConversion() {
        #expect(ColorHex.string(red: 1, green: 0.2314, blue: 0.1882) == "#FF3B30")
        #expect(ColorHex.string(red: 0, green: 0, blue: 0) == "#000000")
        #expect(ColorHex.string(red: 2, green: -1, blue: 0.5) == "#FF0080")
    }

    @Test func modelsRoundTripThroughJSON() throws {
        let e = CalendarEvent(
            id: "1", calendarID: "c", calendarTitle: "C", colorHex: "#FFFFFF", title: "t",
            start: t0, end: t0.addingTimeInterval(60), isAllDay: false)
        let v = try JSONValue(encoding: e)
        #expect(try v.decode(CalendarEvent.self) == e)
    }
}
