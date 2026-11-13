import ApnumAlarms
import ApnumCore
import ApnumTimers
import ApnumSky
import AppKit
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
    @Environment(\.skyTheme) private var theme
    @State private var editing: AlarmEditing?
    @State private var selection: UUID?

    private var sorted: [Alarm] {
        model.alarmList.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    var body: some View {
        if ProcessInfo.processInfo.environment["APNUM_PREVIEW"] == "alarm-editor" {
            // Debug only (scripts/snapshot.sh alarms:alarm-editor): sheets can't be captured.
            AlarmEditor(alarm: nil).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            screen
        }
    }

    private var screen: some View {
        VStack(spacing: 0) {
            if model.alarmSettings.mirrorToClockApp, model.alarmMirrorError != nil {
                AlarmsMirrorBanner()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
            }
            if model.alarmList.isEmpty {
                ContentUnavailableView {
                    Label("No alarms", systemImage: "alarm")
                } description: {
                    Text("Alarms ring on this Mac, and on your phone once it's paired.")
                } actions: {
                    Button("New alarm") { editing = .new }
                        .buttonStyle(.pill(.accentColor))
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
        guard let next = model.nextAlarm else { return "No alarms on" }
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
                    .listRowInsets(.init(top: 5, leading: 28, bottom: 5, trailing: 28))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .skyPage(theme)
        .onKeyPress(.return) {
            guard let id = selection, let alarm = model.alarmList.first(where: { $0.id == id }) else { return .ignored }
            editing = .edit(alarm)
            return .handled
        }
        .onDeleteCommand {
            if let id = selection, let alarm = model.alarmList.first(where: { $0.id == id }) { delete(alarm) }
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
    @Environment(\.skyTheme) private var theme
    let alarm: Alarm

    /// The sky when this alarm next rings, if the location is known.
    private var moment: ClockSkyMoment? {
        guard let location = model.skySettings?.location,
            let date = ClockSkyMoment.nextRing(hour: alarm.hour, minute: alarm.minute, days: alarm.repeatDays)
        else { return nil }
        return ClockSkyMoment(at: date, location: location)
    }

    var body: some View {
        HStack(spacing: 18) {
            if let moment {
                SkyChip(
                    moment: moment, dimmed: !alarm.isEnabled,
                    moonPhase: model.skyScene?.moonPhase ?? 0.5, moonFraction: model.skyScene?.moonFraction ?? 1)
            }
            ClockText(hour: alarm.hour, minute: alarm.minute, size: 48, weight: .thin)
                .frame(minWidth: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                    .font(.body)
                    .lineLimit(1)
                Text(AlarmRepeat.summary(alarm.repeatDays))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let moment {
                    Text(moment.caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
        .padding(.horizontal, 18)
        .frame(height: 84)
        .skyPanel(theme)
        .opacity(alarm.isEnabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.2), value: alarm.isEnabled)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Mirror banner

private struct AlarmsMirrorBanner: View {
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
            .buttonStyle(.pill)
            .disabled(retrying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.orange.opacity(0.14)), in: .rect(cornerRadius: 16))
    }
}

// MARK: - Editor

/// Maps between the stored 24-hour time and what the digit field shows.
/// In 12-hour mode the field holds 1...12 and a separate AM/PM flag carries the rest.
private enum AlarmTimeEntry {
    static func entry(hour: Int, minute: Int, twelveHour: Bool) -> DigitEntry {
        if twelveHour {
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            return DigitEntry(values: [h12, minute], ranges: [1...12, 0...59])
        }
        return DigitEntry(values: [hour, minute], ranges: [0...23, 0...59])
    }

    static func hour24(_ entry: DigitEntry, twelveHour: Bool, pm: Bool) -> Int {
        let h = entry.values[0]
        return twelveHour ? (h % 12) + (pm ? 12 : 0) : h
    }
}

private struct AlarmEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let alarm: Alarm?
    private let twelveHour: Bool
    private let sounds: [String]
    private let originalSnooze: Int
    @State private var entry: DigitEntry
    @State private var pm: Bool
    @State private var label: String
    @State private var days: Set<Weekday>
    @State private var snoozeOn: Bool
    @State private var sound: String
    @State private var soundChanged = false

    init(alarm: Alarm?) {
        self.alarm = alarm
        let hour = alarm?.hour ?? 7, minute = alarm?.minute ?? 0
        let twelve = ClockFormat.parts(.now).1 != nil
        twelveHour = twelve
        _entry = State(initialValue: AlarmTimeEntry.entry(hour: hour, minute: minute, twelveHour: twelve))
        _pm = State(initialValue: hour >= 12)
        _label = State(initialValue: alarm?.label ?? "")
        _days = State(initialValue: alarm?.repeatDays ?? [])
        _snoozeOn = State(initialValue: (alarm?.snoozeMinutes ?? 9) > 0)
        originalSnooze = alarm?.snoozeMinutes ?? 9
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds"))?
            .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted() ?? ["Glass"]
        sounds = names
        _sound = State(initialValue: alarm?.sound ?? "Glass")
    }

    private var hour24: Int { AlarmTimeEntry.hour24(entry, twelveHour: twelveHour, pm: pm) }

    private var moment: ClockSkyMoment? {
        guard let location = model.skySettings?.location,
            let date = ClockSkyMoment.nextRing(hour: hour24, minute: entry.values[1], days: days)
        else { return nil }
        return ClockSkyMoment(at: date, location: location)
    }

    private func setTime(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = parts.hour ?? 0, m = parts.minute ?? 0
        entry = AlarmTimeEntry.entry(hour: h, minute: m, twelveHour: twelveHour)
        pm = h >= 12
    }

    private var skyLine: some View {
        HStack(spacing: 10) {
            if let moment {
                SkyChip(
                    moment: moment, moonPhase: model.skyScene?.moonPhase ?? 0.5,
                    moonFraction: model.skyScene?.moonFraction ?? 1, size: 32)
                Text("The sky then: \(moment.caption)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let rise = model.skySummary?.sunrise {
                Button("Sunrise") { setTime(rise.addingTimeInterval(86_400)) }
                    .buttonStyle(.pill)
            }
            if let set = model.skySummary?.sunset {
                Button("Sunset") { setTime(set) }
                    .buttonStyle(.pill)
            }
        }
        .frame(height: 34)
    }

    private var repeatTitle: String { days.isEmpty ? "Never" : AlarmRepeat.summary(days) }

    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                DigitField(entry: $entry, labels: ["hour", "minute"], size: 76, autofocus: true)
                if twelveHour {
                    Picker("AM or PM", selection: $pm) {
                        Text("AM").tag(false)
                        Text("PM").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.top, 26)
                }
            }
            .frame(maxWidth: .infinity)

            skyLine

            Form {
                Group {
                    LabeledContent("Repeat") { repeatMenu }
                    LabeledContent("Label") {
                        TextField("Label", text: $label, prompt: Text("Alarm"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                    }
                    Picker("Sound", selection: $sound) {
                        ForEach(sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: sound) {
                        soundChanged = true
                        NSSound(named: NSSound.Name(sound))?.play()
                    }
                    Toggle("Snooze", isOn: $snoozeOn)
                }
                .listRowBackground(theme.isActive ? theme.panel : nil)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: 206)

            HStack {
                if alarm != nil {
                    Button("Delete alarm", role: .destructive, action: delete)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill(width: 96))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.pill(.accentColor, width: 96))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 440)
        .background(theme.isActive ? theme.background : Color.clear)
    }

    private var repeatMenu: some View {
        Menu(repeatTitle) {
            Button("Never") { days = [] }
            Button("Every day") { days = Set(Weekday.allCases) }
            Button("Weekdays") { days = [.monday, .tuesday, .wednesday, .thursday, .friday] }
            Button("Weekends") { days = [.saturday, .sunday] }
            Divider()
            ForEach(weekOrder, id: \.self) { day in
                Toggle(day.clockName, isOn: Binding(
                    get: { days.contains(day) },
                    set: { on in if on { days.insert(day) } else { days.remove(day) } }))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func save() {
        let hour = hour24
        let snooze = snoozeOn ? (originalSnooze > 0 ? originalSnooze : 9) : 0
        var input: [String: JSONValue] = [
            "hour": .number(Double(hour)), "minute": .number(Double(entry.values[1])),
            "label": .string(label.trimmingCharacters(in: .whitespaces)),
            "repeatDays": .array(weekOrder.filter(days.contains).map { .string($0.wireName) }),
            "snoozeMinutes": .number(Double(snooze)),
        ]
        if alarm == nil || soundChanged { input["sound"] = .string(sound) }
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
