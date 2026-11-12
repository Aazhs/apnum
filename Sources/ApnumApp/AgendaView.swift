import ApnumCalendar
import ApnumCore
import AppKit
import SwiftUI

/// Agenda: upcoming calendar events and open reminders.
struct AgendaView: View {
    private enum Part: String, CaseIterable, Identifiable {
        case events = "Events", reminders = "Reminders"
        var id: String { rawValue }
    }

    @State private var part: Part = .events

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $part) {
                ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            switch part {
            case .events: EventsPane()
            case .reminders: RemindersPane()
            }
        }
    }
}

// MARK: - Access

private struct AccessCard: View {
    @Environment(AppModel.self) private var model
    let state: AccessState
    let noun: String
    let pane: String

    private var blocked: Bool { state == .denied || state == .restricted }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: blocked ? "lock.fill" : "calendar.badge.clock")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Allow access to \(noun)").font(.headline)
            if blocked {
                Text("Access was turned off. Enable apnum under Privacy & Security \u{2192} \(pane) in System Settings.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("apnum shows your \(noun) here and lets you and your agents add to them. Nothing leaves this Mac.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Allow access") { Task { await model.requestCalendarAccess() } }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(20)
    }
}

private enum AgendaFormat {
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}

private extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .accentColor; return }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Events

private struct EventsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    private var days: [(day: Date, events: [CalendarEvent])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: model.upcomingEvents) { cal.startOfDay(for: $0.start) }
        return dict.keys.sorted().map { ($0, dict[$0]!.sorted { $0.start < $1.start }) }
    }

    private func heading(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        if model.eventAccess != .granted {
            AccessCard(state: model.eventAccess, noun: "Calendar", pane: "Calendars")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Next 7 days").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New event")
                        .accessibilityLabel("New event")
                        .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                            QuickAddEvent { showAdd = false }
                        }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                if days.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nothing coming up").font(.headline)
                        Text("No events in the next 7 days.").font(.callout).foregroundStyle(.secondary)
                        Button("New Event") { showAdd = true }.buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(days, id: \.day) { group in
                            SwiftUI.Section(heading(group.day)) {
                                ForEach(group.events) { event in
                                    EventRow(event: event)
                                        .contextMenu {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                Task { await model.run("calendar.event.delete", ["id": .string(event.id)]) }
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(event.start.formatted(f)) \u{2013} \(event.end.formatted(f))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color(hex: event.colorHex)).frame(width: 8, height: 8).padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.body).lineLimit(2)
                Text(timeText).font(.caption).foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

private struct QuickAddEvent: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var title = ""
    @State private var start = Calendar.current.date(
        bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()
    @State private var duration = 60
    @State private var allDay = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Event").font(.headline)
            TextField("Title", text: $title)
                .focused($focused)
                .onSubmit(add)
            Toggle("All day", isOn: $allDay)
            DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            if !allDay {
                Picker("Duration", selection: $duration) {
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                    Text("90 min").tag(90)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14).frame(width: 280)
        .onAppear { focused = true }
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var input: [String: JSONValue] = ["title": .string(t)]
        if allDay {
            input["start"] = .string(AgendaFormat.iso(Calendar.current.startOfDay(for: start)))
            input["isAllDay"] = true
        } else {
            input["start"] = .string(AgendaFormat.iso(start))
            input["durationMinutes"] = .number(Double(duration))
        }
        done()
        Task { await model.run("calendar.event.create", .object(input)) }
    }
}

// MARK: - Reminders

private struct RemindersPane: View {
    @Environment(AppModel.self) private var model
    @State private var newTitle = ""

    var body: some View {
        if model.reminderAccess != .granted {
            AccessCard(state: model.reminderAccess, noun: "Reminders", pane: "Reminders")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                    TextField("Add reminder", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                if model.openReminders.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
                        Text("All done").font(.headline)
                        Text("Type above and press Return to add a reminder.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(model.openReminders) { ReminderRow(reminder: $0) }.listStyle(.plain)
                }
            }
        }
    }

    private func add() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        newTitle = ""
        Task { await model.run("reminders.create", ["title": .string(t)]) }
    }
}

private struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    private var overdue: Bool { (reminder.dueDate ?? .distantFuture) < Date() }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                Task { await model.run("reminders.complete", ["id": .string(reminder.id), "completed": true]) }
            } label: {
                Image(systemName: "circle").font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(reminder.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title).lineLimit(2)
                HStack(spacing: 6) {
                    if let due = reminder.dueDate {
                        Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(overdue ? Color.red : Color.secondary)
                    }
                    Text(reminder.listTitle).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 1)
    }
}
