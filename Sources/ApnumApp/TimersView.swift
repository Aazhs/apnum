import ApnumCore
import ApnumTimers
import SwiftUI

struct TimersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                QuickStart()
                CustomTimerRow()
                if model.timerList.isEmpty {
                    Text("No active timers. Pick a duration above to start one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.timerList) { TimerRow(timer: $0) }
                    }
                }
                Divider()
                StopwatchSection()
            }
            .padding(12)
        }
    }
}

private struct QuickStart: View {
    @Environment(AppModel.self) private var model

    private let presets: [(String, String, Double)] = [
        ("1 min", "minutes", 1), ("3 min", "minutes", 3), ("5 min", "minutes", 5), ("10 min", "minutes", 10),
        ("15 min", "minutes", 15), ("30 min", "minutes", 30), ("1 h", "hours", 1),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick start").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(presets, id: \.0) { title, key, value in
                    Button(title) {
                        Task { await model.run("timer.start", [key: .number(value)]) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct CustomTimerRow: View {
    @Environment(AppModel.self) private var model
    @State private var hours = ""
    @State private var minutes = ""
    @State private var seconds = ""
    @State private var label = ""

    private var total: Double {
        (Double(hours) ?? 0) * 3600 + (Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0)
    }

    var body: some View {
        HStack(spacing: 4) {
            field("h", $hours)
            field("m", $minutes)
            field("s", $seconds)
            TextField("Label", text: $label).textFieldStyle(.roundedBorder)
            Button("Start", action: start)
                .disabled(total < 1)
                .keyboardShortcut(.defaultAction)
        }
        .onSubmit(start)
    }

    private func field(_ unit: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 2) {
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 40)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func start() {
        guard total >= 1 else { return }
        let name = label.trimmingCharacters(in: .whitespaces)
        var input: JSONValue = ["seconds": .number(total)]
        if !name.isEmpty { input = ["seconds": .number(total), "label": .string(name)] }
        Task {
            if await model.run("timer.start", input) != nil {
                hours = ""; minutes = ""; seconds = ""; label = ""
            }
        }
    }
}

private struct TimerRow: View {
    @Environment(AppModel.self) private var model
    let timer: CountdownTimer

    private var id: JSONValue { .string(timer.id.uuidString) }

    var body: some View {
        HStack(spacing: 10) {
            ring
            VStack(alignment: .leading, spacing: 2) {
                countdown
                    .font(.system(size: 22, weight: .light))
                    .monospacedDigit()
                Text(timer.label.isEmpty ? TimerFormat.string(timer.duration) : timer.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            controls
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var countdown: some View {
        switch timer.state {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TimerFormat.string(timer.remaining(at: ctx.date)))
            }
        case .paused:
            Text(TimerFormat.string(timer.remaining(at: .now))).foregroundStyle(.secondary)
        case .ringing, .finished:
            Text("Done").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var ring: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            if timer.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    arc(timer.remaining(at: ctx.date))
                }
            } else {
                arc(timer.remaining(at: .now))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private func arc(_ remaining: TimeInterval) -> some View {
        Circle()
            .trim(from: 0, to: timer.duration > 0 ? min(1, remaining / timer.duration) : 0)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            switch timer.state {
            case .ringing, .finished:
                Button("Stop") { act("timer.stop") }.buttonStyle(.borderedProminent).controlSize(.small)
            case .running, .paused:
                iconButton(timer.state == .running ? "pause.fill" : "play.fill",
                           timer.state == .running ? "Pause timer" : "Resume timer") {
                    act(timer.state == .running ? "timer.pause" : "timer.resume")
                }
                Button("+1 min") {
                    Task { await model.run("timer.add_time", ["id": id, "seconds": 60]) }
                }
                .controlSize(.small)
                iconButton("xmark", "Cancel timer") { act("timer.cancel") }
            }
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .controlSize(.small)
            .accessibilityLabel(label)
            .help(label)
    }

    private func act(_ tool: String) {
        Task { await model.run(tool, ["id": id]) }
    }
}

private struct StopwatchSection: View {
    @Environment(AppModel.self) private var model

    private func clock(_ t: TimeInterval) -> String {
        let cs = Int(t * 100)
        let h = cs / 360_000, m = (cs / 6000) % 60, s = (cs / 100) % 60, c = cs % 100
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, c) : String(format: "%02d:%02d.%02d", m, s, c)
    }

    var body: some View {
        let sw = model.stopwatch
        VStack(alignment: .leading, spacing: 8) {
            Text("Stopwatch").font(.caption).foregroundStyle(.secondary)
            HStack {
                if sw.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(TimerFormat.string(sw.elapsed(at: ctx.date).rounded(.down)))
                    }
                } else {
                    Text(TimerFormat.string(sw.elapsed(at: .now).rounded(.down)))
                }
                Spacer()
                Button("Reset") { control("reset") }
                    .disabled(sw.isRunning || (sw.accumulated == 0 && sw.laps.isEmpty))
                Button("Lap") { control("lap") }.disabled(!sw.isRunning)
                Button(sw.isRunning ? "Pause" : "Start") { control(sw.isRunning ? "pause" : "start") }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .font(.system(size: 22, weight: .light))
            .monospacedDigit()
            if !sw.laps.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(sw.laps.enumerated()).reversed(), id: \.offset) { index, total in
                        let split = total - (index > 0 ? sw.laps[index - 1] : 0)
                        HStack {
                            Text("Lap \(index + 1)").foregroundStyle(.secondary)
                            Spacer()
                            Text(clock(split))
                            Text(clock(total)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                        }
                        .font(.callout)
                        .monospacedDigit()
                    }
                }
            }
        }
    }

    private func control(_ action: String) {
        Task { await model.run("stopwatch.control", ["action": .string(action)]) }
    }
}
