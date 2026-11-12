import ApnumAlarms
import ApnumCore
import SwiftUI

private let weekOrder: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

private enum AlarmEditing: Identifiable {
    case new
    case edit(Alarm)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let alarm): alarm.id.uuidString
        }
    }
}

// MARK: - Screen

struct AlarmsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AlarmEditing?
    @State private var selection: UUID?

    private var sorted: [Alarm] {
        model.alarmList.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.alarmList.isEmpty {
                ContentUnavailableView {
                    Label("No alarms", systemImage: "alarm")
                } description: {
                    Text("Alarms ring on this Mac, and on your phone once it's paired.")
                } actions: {
                    Button("New alarm") { editing = .new }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("Alarms")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New alarm", systemImage: "plus") { editing = .new }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $editing) { target in
            switch target {
            case .new: AlarmEditor(alarm: nil)
            case .edit(let alarm): AlarmEditor(alarm: alarm)
            }
        }
    }

    private var subtitle: String {
        guard let next = model.nextAlarm else { return model.alarmList.isEmpty ? "" : "No alarm is on" }
        return "Next \(ClockFormat.relative(to: next.date))"
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(sorted) { alarm in
                AlarmRow(alarm: alarm)
                    .tag(alarm.id)
                    .contentShape(.rect)
                    .onTapGesture {
                        selection = alarm.id
                        editing = .edit(alarm)
                    }
                    .contextMenu {
                        Button("Edit") { editing = .edit(alarm) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(alarm) }
                    }
                    .listRowInsets(.init(top: 4, leading: 28, bottom: 4, trailing: 28))
            }
        }
        .onDeleteCommand {
            if let id = selection, let alarm = model.alarmList.first(where: { $0.id == id }) { delete(alarm) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.alarmSettings.mirrorToClockApp, model.alarmMirrorError != nil {
                MirrorBanner()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
            }
        }
    }

    private func delete(_ alarm: Alarm) {
        Task { await model.run("alarm.delete", ["id": .string(alarm.id.uuidString)]) }
        if selection == alarm.id { selection = nil }
    }
}

// MARK: - Row

private struct AlarmRow: View {
    @Environment(AppModel.self) private var model
    let alarm: Alarm

    var body: some View {
        HStack(spacing: 16) {
            ClockText(hour: alarm.hour, minute: alarm.minute, size: 46, weight: .thin)
                .frame(minWidth: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                    .font(.body)
                    .lineLimit(1)
                Text(AlarmRepeat.summary(alarm.repeatDays))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("Enabled", isOn: Binding(
                get: { alarm.isEnabled },
                set: { value in
                    Task {
                        await model.run("alarm.update", ["id": .string(alarm.id.uuidString), "isEnabled": .bool(value)])
                    }
                }))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 6)
        .opacity(alarm.isEnabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.2), value: alarm.isEnabled)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Mirror banner

private struct MirrorBanner: View {
    @Environment(AppModel.self) private var model
    @State private var retrying = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Your alarms could not be copied to the Clock app, so they may not ring there.")
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Try again") {
                retrying = true
                Task {
                    await model.run("alarm.mirror.sync")
                    retrying = false
                }
            }
            .buttonStyle(.glass)
            .disabled(retrying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.orange.opacity(0.14)), in: .rect(cornerRadius: 16))
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editor

private struct AlarmEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let alarm: Alarm?
    @State private var time: Date
    @State private var label: String
    @State private var days: Set<Weekday>
    @State private var snooze: Int

    init(alarm: Alarm?) {
        self.alarm = alarm
        let cal = Calendar.current
        let base = cal.date(bySettingHour: alarm?.hour ?? 7, minute: alarm?.minute ?? 0, second: 0, of: .now) ?? .now
        _time = State(initialValue: base)
        _label = State(initialValue: alarm?.label ?? "")
        _days = State(initialValue: alarm?.repeatDays ?? [])
        _snooze = State(initialValue: alarm?.snoozeMinutes ?? 9)
    }

    private var snoozeOptions: [Int] {
        Array(Set([0, 5, 9, 10, 15, snooze])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ClockText(time, size: 64, weight: .thin)
                .frame(maxWidth: .infinity)

            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(maxWidth: .infinity)

            TextField("Label", text: $label, prompt: Text("Alarm"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Repeat").font(.subheadline).foregroundStyle(.secondary)
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(weekOrder, id: \.self) { day in
                            let on = days.contains(day)
                            Button {
                                if on { days.remove(day) } else { days.insert(day) }
                            } label: {
                                Text(day.shortName)
                                    .font(.callout.weight(on ? .semibold : .regular))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .tint(on ? Color.accentColor : nil)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                Text(AlarmRepeat.summary(days))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Picker("Snooze", selection: $snooze) {
                ForEach(snoozeOptions, id: \.self) { Text($0 == 0 ? "Off" : "\($0) min").tag($0) }
            }

            HStack {
                if alarm != nil {
                    Button("Delete alarm", role: .destructive, action: delete)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 420)
    }

    private func save() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        var input: [String: JSONValue] = [
            "hour": .number(Double(c.hour ?? 0)), "minute": .number(Double(c.minute ?? 0)),
            "label": .string(label.trimmingCharacters(in: .whitespaces)),
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
        Task { await model.run(tool, .object(input)) }
        dismiss()
    }

    private func delete() {
        guard let alarm else { return }
        Task { await model.run("alarm.delete", ["id": .string(alarm.id.uuidString)]) }
        dismiss()
    }
}
