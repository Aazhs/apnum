import ApnumCalendar
import ApnumCore
import SwiftUI

/// The week ahead: a strip of the next eight days over an agenda grouped by day.
struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewEvent = false

    private var cal: Calendar { .current }
    private var today: Date { cal.startOfDay(for: .now) }
    private var days: [Date] { (0..<8).compactMap { cal.date(byAdding: .day, value: $0, to: today) } }

    var body: some View {
        Group {
            if model.eventAccess != .granted && !model.isDemo {
                AccessUnavailable(
                    title: "Calendar access is off", symbol: "calendar.badge.exclamationmark",
                    what: "apnum shows and edits events in your Apple Calendar, including iCloud and Google accounts you have added to macOS.",
                    denied: model.eventAccess == .denied || model.eventAccess == .restricted,
                    settingsPane: "Privacy_Calendars")
            } else {
                content
            }
        }
        .navigationTitle("Calendar")
        .navigationSubtitle("This week")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New event", systemImage: "plus") { showingNewEvent = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.eventAccess != .granted && !model.isDemo)
            }
        }
        .sheet(isPresented: $showingNewEvent) { NewEventSheet() }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                WeekStrip(days: days, events: model.upcomingEvents) { day in
                    withAnimation(.smooth) { proxy.scrollTo(day, anchor: .top) }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: 760 + 56, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView {
                    TimelineView(.everyMinute) { context in
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(days, id: \.self) { day in
                                DaySection(day: day, now: context.date, events: events(on: day))
                                    .id(day)
                            }
                        }
                        .padding(.horizontal, 36)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 760 + 72, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func events(on day: Date) -> [CalendarEvent] {
        let end = cal.date(byAdding: .day, value: 1, to: day) ?? day
        return model.upcomingEvents
            .filter { $0.start < end && $0.end > day }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
    }
}

// MARK: - Week strip

private struct WeekStrip: View {
    let days: [Date]
    let events: [CalendarEvent]
    let select: (Date) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                Button { select(day) } label: {
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption)
                            .foregroundStyle(isToday ? Color.accentColor : .secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.clock(20, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(isToday ? Color.white : .primary)
                            .frame(width: 36, height: 36)
                            .background(isToday ? Color.accentColor : .clear, in: .circle)
                        HStack(spacing: 3) {
                            ForEach(Array(colors(on: day).enumerated()), id: \.offset) { _, color in
                                Circle().fill(color).frame(width: 5, height: 5)
                            }
                        }
                        .frame(height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            }
        }
    }

    private func colors(on day: Date) -> [Color] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        var seen: [String] = []
        for event in events where event.start < end && event.end > day {
            if !seen.contains(event.colorHex) { seen.append(event.colorHex) }
        }
        return seen.prefix(4).map { Color(hex: $0) ?? .accentColor }
    }
}

// MARK: - Agenda

private struct DaySection: View {
    let day: Date
    let now: Date
    let events: [CalendarEvent]

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    private var heading: (String, String) {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return ("Today", day.formatted(.dateTime.weekday(.wide).day().month(.wide))) }
        if cal.isDateInTomorrow(day) { return ("Tomorrow", day.formatted(.dateTime.weekday(.wide).day().month(.wide))) }
        return (day.formatted(.dateTime.weekday(.wide)), day.formatted(.dateTime.day().month(.wide)))
    }

    var body: some View {
        let allDay = events.filter(\.isAllDay)
        let timed = events.filter { !$0.isAllDay }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading.0).font(.title3.weight(.semibold))
                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                Text(heading.1).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            if events.isEmpty {
                Text("No events").foregroundStyle(.tertiary).padding(.vertical, 2)
            }
            ForEach(allDay) { event in
                AllDayLine(event: event)
            }
            ForEach(Array(timed.enumerated()), id: \.element.id) { index, event in
                EventRow(event: event, day: day, dimmed: isToday && event.end < now)
                if index < timed.count - 1 { Divider() }
            }
        }
    }
}

private struct AllDayLine: View {
    let event: CalendarEvent

    var body: some View {
        let tint = Color(hex: event.colorHex) ?? .accentColor
        Text(event.title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 6))
            .contextMenu { EventMenu(event: event) }
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let day: Date
    let dimmed: Bool

    var body: some View {
        let tint = Color(hex: event.colorHex) ?? .accentColor
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let start = max(event.start, day), end = min(event.end, nextDay)
        let detail = [event.location, event.calendarTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(ClockFormat.string(start)).font(.callout.weight(.medium))
                Text(ClockFormat.string(end)).font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: 76, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.body.weight(.medium)).lineLimit(2)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4).padding(.vertical, 6)
        }
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(.rect)
        .contextMenu { EventMenu(event: event) }
    }
}

private struct EventMenu: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent

    var body: some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            Task { await model.run("calendar.event.delete", ["id": .string(event.id)]) }
        }
    }
}

// MARK: - New event

private struct NewEventSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var allDay = false
    @State private var start = NewEventSheet.defaultStart()
    @State private var end = NewEventSheet.defaultStart().addingTimeInterval(3600)
    @State private var minutes = 60
    @State private var location = ""
    @State private var calendars: [CalendarInfo] = []
    @State private var calendarID: String?

    private static func defaultStart() -> Date {
        Calendar.current.dateInterval(of: .hour, for: .now)?.end ?? .now
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $title)
                Toggle("All-day", isOn: $allDay)
                DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                if !allDay {
                    Picker("Duration", selection: $minutes) {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                        Text("Choose an end time").tag(0)
                    }
                    if minutes == 0 {
                        DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
                TextField("Location", text: $location)
                Picker("Calendar", selection: $calendarID) {
                    ForEach(calendars) { calendar in
                        Label {
                            Text(calendar.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: calendar.colorHex) ?? .accentColor)
                        }
                        .tag(Optional(calendar.id))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 440)
        .task {
            calendars = ((try? await model.calendar.calendars()) ?? []).filter(\.allowsModifications)
            if calendarID == nil { calendarID = calendars.first?.id }
        }
    }

    private func save() {
        var input: [String: JSONValue] = [
            "title": .string(title.trimmingCharacters(in: .whitespaces)),
            "start": .string(Self.iso(start)),
            "isAllDay": .bool(allDay),
        ]
        if !allDay {
            input["end"] = .string(Self.iso(minutes == 0 ? max(end, start) : start.addingTimeInterval(Double(minutes) * 60)))
        }
        if !location.trimmingCharacters(in: .whitespaces).isEmpty { input["location"] = .string(location) }
        if let calendarID { input["calendarID"] = .string(calendarID) }
        Task {
            await model.run("calendar.event.create", .object(input))
            dismiss()
        }
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }
}

// MARK: - Access

private struct AccessUnavailable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let title: String
    let symbol: String
    let what: String
    let denied: Bool
    let settingsPane: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(what)
        } actions: {
            if denied {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)") { openURL(url) }
                }
                .buttonStyle(.glassProminent)
            } else {
                Button("Allow access") { Task { await model.requestCalendarAccess() } }
                    .buttonStyle(.glassProminent)
            }
        }
    }
}
