import ApnumAlarms
import ApnumCore
import SwiftUI

private let weekOrder: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

private func repeatSummary(_ days: Set<Weekday>) -> String {
    if days.isEmpty { return "Once" }
    if days.count == 7 { return "Every day" }
    if days == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "Weekdays" }
    if days == [.saturday, .sunday] { return "Weekends" }
    return weekOrder.filter(days.contains).map(\.shortName).joined(separator: ", ")
}

private func untilText(_ date: Date, now: Date = Date()) -> String {
    let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
    if d > 0 { return "in \(d) d \(h) h" }
    if h > 0 { return "in \(h) h \(m) min" }
    return "in \(m) min"
}

private enum AlarmEditing: Identifiable {
    case new
    case edit(Alarm)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let a): a.id.uuidString
        }
    }
}

struct AlarmsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AlarmEditing?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.alarmSettings.mirrorToClockApp, let error = model.alarmMirrorError {
                mirrorWarning(error)
                Divider()
            }
            if model.alarmList.isEmpty {
                ContentUnavailableView {
                    Label("No alarms", systemImage: "alarm")
                } description: {
                    Text("Add an alarm to get woken up or reminded.")
                } actions: {
                    Button("Add Alarm") { editing = .new }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.alarmList) { alarm in
                        AlarmRow(alarm: alarm, onEdit: { editing = .edit(alarm) })
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $editing) { item in
            switch item {
            case .new: AlarmEditor(alarm: nil)
            case .edit(let a): AlarmEditor(alarm: a)
            }
        }
    }

    private var header: some View {
        HStack {
            Group {
                if let next = model.nextAlarm {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("Next: \(next.date.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())) · \(untilText(next.date, now: ctx.date))")
                    }
                } else {
                    Text("No upcoming alarm")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            Spacer()
            Button { editing = .new } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add alarm")
                .help("Add alarm")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func mirrorWarning(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Clock app sync failed: \(error)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
            Button("Retry") { Task { await model.run("alarm.mirror.sync") } }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct AlarmRow: View {
    @Environment(AppModel.self) private var model
    let alarm: Alarm
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.timeText).font(.system(size: 30, weight: .light)).monospacedDigit()
                HStack(spacing: 4) {
                    if !alarm.label.isEmpty { Text(alarm.label); Text("·") }
                    Text(repeatSummary(alarm.repeatDays))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { alarm.isEnabled },
                set: { value in
                    Task { await model.run("alarm.update", ["id": .string(alarm.id.uuidString), "isEnabled": .bool(value)]) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .opacity(alarm.isEnabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive) { delete() }
        }
    }

    private func delete() {
        Task { await model.run("alarm.delete", ["id": .string(alarm.id.uuidString)]) }
    }
}

private struct AlarmEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let alarm: Alarm?

    @State private var time = Date()
    @State private var label = ""
    @State private var days: Set<Weekday> = []
    @State private var snooze = 9
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(alarm == nil ? "New Alarm" : "Edit Alarm").font(.headline)
            HStack {
                Spacer()
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .scaleEffect(1.3)
                    .padding(.vertical, 6)
                Spacer()
            }
            TextField("Label", text: $label).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Text("Repeat").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(weekOrder, id: \.self) { day in
                        Toggle(day.shortName, isOn: Binding(
                            get: { days.contains(day) },
                            set: { if $0 { days.insert(day) } else { days.remove(day) } }))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
                Text(repeatSummary(days)).font(.caption).foregroundStyle(.secondary)
            }
            Stepper(value: $snooze, in: 0...180) {
                Text(snooze == 0 ? "Snooze: off" : "Snooze: \(snooze) min").monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let alarm {
                time = Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date()
                label = alarm.label
                days = alarm.repeatDays
                snooze = alarm.snoozeMinutes
            } else {
                time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
            }
        }
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        var input: [String: JSONValue] = [
            "hour": .number(Double(comps.hour ?? 7)),
            "minute": .number(Double(comps.minute ?? 0)),
            "label": .string(label),
            "repeatDays": .array(weekOrder.filter(days.contains).map { .string($0.wireName) }),
            "snoozeMinutes": .number(Double(snooze)),
        ]
        let tool: String
        if let alarm {
            tool = "alarm.update"
            input["id"] = .string(alarm.id.uuidString)
        } else {
            tool = "alarm.create"
        }
        let payload = JSONValue.object(input)
        Task {
            if await model.run(tool, payload) != nil { dismiss() }
        }
    }
}
