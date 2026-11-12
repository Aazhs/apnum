import ApnumCore
import ApnumTimers
import SwiftUI

// MARK: - Screen

struct TimersView: View {
    @Environment(AppModel.self) private var model

    private var active: [CountdownTimer] {
        model.timerList.filter { $0.state != .finished }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                rings
                StartTimerSection()
                StopwatchSection()
            }
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Timers")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let running = model.timerList.filter { $0.state == .running }.count
        let ringing = model.timerList.filter { $0.state == .ringing }.count
        if ringing > 0 { return ringing == 1 ? "1 timer is ringing" : "\(ringing) timers are ringing" }
        switch running {
        case 0: return "None running"
        case 1: return "1 running"
        default: return "\(running) running"
        }
    }

    @ViewBuilder
    private var rings: some View {
        if active.isEmpty {
            Text("No timers running. Pick a length below.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 28, alignment: .top)],
                      alignment: .leading, spacing: 32) {
                ForEach(active) { timer in
                    TimerRing(timer: timer)
                }
            }
        }
    }
}

// MARK: - Ring

private func remaining(of timer: CountdownTimer, at date: Date) -> TimeInterval {
    switch timer.state {
    case .running: max(0, (timer.endsAt ?? date).timeIntervalSince(date))
    case .paused: timer.pausedRemaining ?? timer.duration
    case .ringing, .finished: 0
    }
}

private struct TimerRing: View {
    @Environment(AppModel.self) private var model
    let timer: CountdownTimer
    @State private var pulse = false

    private var ringing: Bool { timer.state == .ringing }
    private var paused: Bool { timer.state == .paused }
    private var tint: Color { ringing ? .orange : .accentColor }

    var body: some View {
        VStack(spacing: 14) {
            if timer.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    face(at: context.date)
                }
            } else {
                face(at: .now)
            }
            controls
        }
        .frame(maxWidth: .infinity)
    }

    private func face(at date: Date) -> some View {
        let left = remaining(of: timer, at: date)
        let progress = ringing ? 1 : (timer.duration > 0 ? min(1, left / timer.duration) : 0)
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text(ringing ? "0:00" : TimerFormat.string(left))
                    .font(.clock(40, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text(timer.label.isEmpty ? TimerFormat.string(timer.duration) : timer.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
            }
        }
        .frame(width: 180, height: 180)
        .opacity(paused ? 0.55 : (ringing && pulse ? 0.55 : 1))
        .onAppear { updatePulse() }
        .onChange(of: ringing) { updatePulse() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timer.label.isEmpty ? "Timer" : timer.label)
        .accessibilityValue(ringing ? "Finished" : TimerFormat.string(left))
    }

    private func updatePulse() {
        if ringing {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.default) { pulse = false }
        }
    }

    private var controls: some View {
        let id = timer.id.uuidString
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if ringing {
                    Button("Stop") { Task { await model.run("timer.cancel", ["id": .string(id)]) } }
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                } else {
                    Button(paused ? "Resume" : "Pause") {
                        Task { await model.run(paused ? "timer.resume" : "timer.pause", ["id": .string(id)]) }
                    }
                    .buttonStyle(.glass)
                }
                Button("+1 min") {
                    Task { await model.run("timer.add_time", ["id": .string(id), "seconds": 60]) }
                }
                .buttonStyle(.glass)
                if !ringing {
                    Button("Cancel") { Task { await model.run("timer.cancel", ["id": .string(id)]) } }
                        .buttonStyle(.glass)
                }
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Start a timer

private struct StartTimerSection: View {
    @Environment(AppModel.self) private var model
    @State private var hours = 0
    @State private var minutes = 10
    @State private var seconds = 0
    @State private var label = ""

    private let presets: [(title: String, seconds: Double)] = [
        ("1 min", 60), ("3 min", 180), ("5 min", 300), ("10 min", 600), ("15 min", 900),
        ("25 min", 1500), ("45 min", 2700), ("1 h", 3600),
    ]

    private var total: Double { Double(hours * 3600 + minutes * 60 + seconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Start a timer")

            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(presets, id: \.title) { preset in
                        Button(preset.title) { start(preset.seconds, label: "") }
                            .buttonStyle(.glass)
                    }
                }
            }

            HStack(spacing: 18) {
                unit("h", value: $hours, range: 0...23)
                unit("min", value: $minutes, range: 0...59)
                unit("s", value: $seconds, range: 0...59)
            }
            .controlSize(.large)
            HStack(spacing: 14) {
                TextField("Label", text: $label, prompt: Text("Label (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button("Start") { start(total, label: label) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(total < 1)
            }
            .controlSize(.large)
        }
    }

    private func unit(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 4) {
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
            Text(title).foregroundStyle(.secondary).fixedSize()
            Stepper(title, value: value, in: range).labelsHidden()
        }
    }

    private func start(_ seconds: Double, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        Task {
            var input: [String: JSONValue] = ["seconds": .number(seconds)]
            if !trimmed.isEmpty { input["label"] = .string(trimmed) }
            await model.run("timer.start", .object(input))
        }
        self.label = ""
    }
}

// MARK: - Stopwatch

private struct StopwatchSection: View {
    @Environment(AppModel.self) private var model

    private var watch: Stopwatch { model.stopwatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Stopwatch")

            HStack(alignment: .center, spacing: 28) {
                readout
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(watch.isRunning ? "Pause" : (watch.elapsed(at: .now) > 0 ? "Resume" : "Start")) {
                            control(watch.isRunning ? "pause" : "start")
                        }
                        .buttonStyle(.glassProminent)
                        Button("Lap") { control("lap") }
                            .buttonStyle(.glass)
                            .disabled(!watch.isRunning)
                        Button("Reset") { control("reset") }
                            .buttonStyle(.glass)
                            .disabled(watch.isRunning || watch.elapsed(at: .now) == 0)
                    }
                }
                .controlSize(.large)
            }

            if !watch.laps.isEmpty {
                laps
            }
        }
    }

    @ViewBuilder
    private var readout: some View {
        if watch.isRunning {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(Self.format(watch.elapsed(at: context.date), tenths: true))
                    .font(.clock(56, weight: .thin))
                    .monospacedDigit()
            }
        } else {
            Text(Self.format(watch.accumulated, tenths: true))
                .font(.clock(56, weight: .thin))
                .monospacedDigit()
        }
    }

    private var laps: some View {
        let totals = watch.laps
        return VStack(spacing: 0) {
            ForEach(Array(totals.enumerated().reversed()), id: \.offset) { index, total in
                let split = total - (index > 0 ? totals[index - 1] : 0)
                HStack {
                    Text("Lap \(index + 1)").foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.format(split, tenths: true)).frame(width: 110, alignment: .trailing)
                    Text(Self.format(total, tenths: true)).foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.vertical, 8)
                Divider()
            }
        }
        .frame(maxWidth: 520)
    }

    private func control(_ action: String) {
        Task { await model.run("stopwatch.control", ["action": .string(action)]) }
    }

    /// "0:07.3", "12:03.9", "1:02:03.0".
    static func format(_ seconds: TimeInterval, tenths: Bool) -> String {
        let t = max(0, Int((seconds * 10).rounded(.down)))
        let h = t / 36000, m = (t / 600) % 60, s = (t / 10) % 60, d = t % 10
        let head = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return tenths ? "\(head).\(d)" : head
    }
}
