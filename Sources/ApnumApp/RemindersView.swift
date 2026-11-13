import ApnumCalendar
import ApnumCore
import SwiftUI

/// Open reminders grouped by list, with a floating quick-add bar.
struct RemindersView: View {
    @Environment(AppModel.self) private var model
    @State private var lists: [ReminderList] = []
    @State private var filterID: String?
    @State private var completing: Set<String> = []

    private var visible: [Reminder] {
        model.openReminders.filter { !completing.contains($0.id) && (filterID == nil || $0.listID == filterID) }
    }

    private var groups: [(list: ReminderList, items: [Reminder])] {
        var known = lists
        for r in visible where !known.contains(where: { $0.id == r.listID }) {
            known.append(ReminderList(id: r.listID, title: r.listTitle, colorHex: ""))
        }
        return known.compactMap { list in
            let items = visible.filter { $0.listID == list.id }.sorted {
                ($0.dueDate ?? .distantFuture, $0.title) < ($1.dueDate ?? .distantFuture, $1.title)
            }
            return items.isEmpty ? nil : (list, items)
        }
    }

    var body: some View {
        Group {
            if model.reminderAccess != .granted && !model.isDemo {
                AccessUnavailable(denied: model.reminderAccess == .denied || model.reminderAccess == .restricted)
            } else {
                content
            }
        }
        .navigationTitle("Reminders")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("List", selection: $filterID) {
                        Text("All lists").tag(String?.none)
                        Divider()
                        ForEach(lists) { list in Text(list.title).tag(Optional(list.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(lists.first { $0.id == filterID }?.title ?? "All lists", systemImage: "line.3.horizontal.decrease")
                }
                .disabled(model.reminderAccess != .granted && !model.isDemo)
            }
        }
        .task(id: model.openReminders.count) {
            lists = (try? await model.calendar.reminderLists()) ?? []
        }
    }

    private var subtitle: String {
        let n = visible.count
        return n == 0 ? "All done" : "\(n) open"
    }

    /// "2 overdue, 1 due today".
    private var summaryLine: String {
        let now = Date.now
        let overdue = visible.filter { $0.dueDate.map { DueText(date: $0, now: now).overdue } ?? false }.count
        let today = visible.filter { r in
            guard let d = r.dueDate else { return false }
            return Calendar.current.isDateInToday(d) && !DueText(date: d, now: now).overdue
        }.count
        var parts: [String] = []
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if today > 0 { parts.append("\(today) due today") }
        return parts.isEmpty ? "Nothing due today" : parts.joined(separator: ", ")
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !visible.isEmpty { Text(summaryLine).font(.callout).foregroundStyle(.secondary).padding(.bottom, -10) }
                ForEach(groups, id: \.list.id) { group in
                    ListSection(list: group.list, items: group.items) { id in
                        withAnimation(.smooth(duration: 0.3)) { _ = completing.insert(id) }
                    }
                }
                if groups.isEmpty {
                    ContentUnavailableView("All done", systemImage: "checkmark.circle", description: Text("Nothing left to do."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 720 + 72, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            QuickAddBar(lists: lists, preferredListID: filterID)
                .padding(.horizontal, 36)
                .padding(.bottom, 16)
                .padding(.top, 6)
        }
    }
}

// MARK: - Grouping and rows

private struct ListSection: View {
    @Environment(\.skyTheme) private var theme
    let list: ReminderList
    let items: [Reminder]
    let onComplete: (String) -> Void

    var body: some View {
        let tint = Color(hex: list.colorHex) ?? .accentColor
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(list.title).font(.headline).foregroundStyle(tint)
                Spacer()
                Text("\(items.count)").font(.headline).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.edge).frame(height: 1) }
            .padding(.bottom, 4)
            ForEach(items) { item in
                ReminderRow(reminder: item, tint: tint, onComplete: onComplete)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                if item.id != items.last?.id { Rectangle().fill(theme.edge.opacity(0.6)).frame(height: 1).padding(.leading, 32) }
            }
        }
    }
}

private struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    let tint: Color
    let onComplete: (String) -> Void
    @State private var checked = false

    var body: some View {
        let due = reminder.dueDate.map { DueText(date: $0) }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: complete) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(reminder.title)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let marks = Self.priorityMarks(reminder.priority) {
                        Text(marks).fontWeight(.semibold).foregroundStyle(tint)
                    }
                    Text(reminder.title).lineLimit(2)
                }
                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes.replacingOccurrences(of: "\n", with: " "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let due {
                    Text(due.text).font(.callout).foregroundStyle(due.overdue ? Color.red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .contextMenu {
            Button("Due today", systemImage: "calendar") { setDue(DueChoice.today.date()) }
            Button("Due tomorrow", systemImage: "calendar.badge.clock") { setDue(DueChoice.tomorrow.date()) }
            Button("No due date", systemImage: "calendar.badge.minus") { setDue(nil) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation(.smooth(duration: 0.3)) { onComplete(reminder.id) }
                Task { await model.run("reminders.delete", ["id": .string(reminder.id)]) }
            }
        }
    }

    private func complete() {
        withAnimation(.snappy) { checked = true }
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            onComplete(reminder.id)
            await model.run("reminders.complete", ["id": .string(reminder.id), "completed": true])
        }
    }

    private func setDue(_ date: Date?) {
        var input: [String: JSONValue] = ["id": .string(reminder.id)]
        if let date { input["dueDate"] = .string(isoString(date)) } else { input["clearDueDate"] = true }
        Task { await model.run("reminders.update", .object(input)) }
    }

    /// EventKit priority: 1-4 high, 5 medium, 6-9 low.
    private static func priorityMarks(_ priority: Int) -> String? {
        switch priority {
        case 1...4: "!!!"
        case 5: "!!"
        case 6...9: "!"
        default: nil
        }
    }
}

/// "Today 18:00", "Tomorrow", "Friday", "3 Dec", red when overdue.
private struct DueText {
    let text: String
    let overdue: Bool

    init(date: Date, now: Date = .now) {
        let cal = Calendar.current
        let hasTime = cal.dateComponents([.hour, .minute], from: date) != DateComponents(hour: 0, minute: 0)
        let time = hasTime ? " " + ClockFormat.string(date) : ""
        overdue = hasTime ? date < now : cal.startOfDay(for: date) < cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: text = "Today" + time
        case 1: text = "Tomorrow" + time
        case -1: text = "Yesterday" + time
        case 2...6: text = date.formatted(.dateTime.weekday(.wide)) + time
        default: text = date.formatted(.dateTime.day().month(.abbreviated)) + time
        }
    }
}

private enum DueChoice: String, CaseIterable {
    case today = "Today", tomorrow = "Tomorrow", weekend = "This weekend"

    func date(now: Date = .now) -> Date {
        let cal = Calendar.current
        func at(_ hour: Int, _ minute: Int = 0, from base: Date) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        switch self {
        case .today:
            for hour in [18, 21] {
                let d = at(hour, from: now)
                if d > now { return d }
            }
            return at(23, 30, from: now)
        case .tomorrow:
            return at(9, from: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        case .weekend:
            let saturday = cal.nextDate(after: now.addingTimeInterval(-86_400), matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) ?? now
            return at(9, from: cal.isDateInWeekend(now) ? now : saturday)
        }
    }
}

private func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f.string(from: date)
}

// MARK: - Quick add

private struct QuickAddBar: View {
    @Environment(AppModel.self) private var model
    let lists: [ReminderList]
    let preferredListID: String?

    @State private var title = ""
    @State private var listID: String?
    @State private var due: DueChoice?
    @FocusState private var focused: Bool

    private var effectiveListID: String? { preferredListID ?? listID ?? lists.first?.id }
    private var list: ReminderList? { lists.first { $0.id == effectiveListID } }
    private var canAdd: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(canAdd ? Color.accentColor : .secondary)
            TextField("New reminder", text: $title)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit(add)
            Menu {
                Picker("List", selection: Binding(get: { effectiveListID }, set: { listID = $0 })) {
                    ForEach(lists) { l in Text(l.title).tag(Optional(l.id)) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: list?.colorHex ?? "") ?? .accentColor).frame(width: 8, height: 8)
                    Text(list?.title ?? "List")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Menu {
                Button("None") { due = nil }
                ForEach(DueChoice.allCases, id: \.self) { choice in Button(choice.rawValue) { due = choice } }
            } label: {
                Label(due?.rawValue ?? "Due", systemImage: "calendar")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add() {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var input: [String: JSONValue] = ["title": .string(text)]
        if let id = effectiveListID { input["listID"] = .string(id) }
        if let due { input["dueDate"] = .string(isoString(due.date())) }
        title = ""
        due = nil
        Task { await model.run("reminders.create", .object(input)) }
    }
}

// MARK: - Access

private struct AccessUnavailable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let denied: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Reminders access is off", systemImage: "checklist")
        } description: {
            Text("apnum uses your Apple Reminders, including iCloud and Google accounts you have added to macOS.")
        } actions: {
            if denied {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { openURL(url) }
                }
                .buttonStyle(.pill(.accentColor))
            } else {
                Button("Allow access") { Task { await model.requestCalendarAccess() } }
                    .buttonStyle(.pill(.accentColor))
            }
        }
    }
}
