import ApnumCore
import ApnumTimers
import SwiftUI

// MARK: - Recents

private struct TimersRecent: Codable, Hashable, Identifiable {
    var seconds: Int
    var label: String
    var id: String { "\(seconds)|\(label)" }

    static let seeds = [60, 180, 300, 600, 900, 1500, 1800].map { TimersRecent(seconds: $0, label: "") }
    static let limit = 12

    /// An empty string means "never stored": show the seeds. A stored "[]" really is empty.
    static func decode(_ json: String) -> [TimersRecent] {
        guard !json.isEmpty else { return seeds }
        return (try? JSONDecoder().decode([TimersRecent].self, from: Data(json.utf8))) ?? seeds
    }

    static func encode(_ list: [TimersRecent]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// "30 min", "1 h 30 min", "45 sec".
    var caption: String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 { parts.append("\(s) sec") }
        let text = parts.joined(separator: " ")
        return label.isEmpty ? text : "\(label), \(text)"
    }
}

// MARK: - Screen

struct TimersView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("timerRecents") private var recentsJSON = ""
    @State private var entry = DigitEntry(values: [0, 10, 0], ranges: [0...23, 0...59, 0...59])
    @State private var label = ""

    private var recents: [TimersRecent] { TimersRecent.decode(recentsJSON) }

    private var active: [CountdownTimer] {
        model.timerList.filter { $0.state != .finished }
    }

    var body: some View {
        HStack(spacing: 0) {
            recentsColumn
                .frame(width: 300)
            Divider()
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Timers")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let running = model.timerList.filter { $0.state == .running }.count
        let ringing = model.timerList.filter { $0.state == .ringing }.count
        if ringing > 0 { return ringing == 1 ? "1 ringing" : "\(ringing) ringing" }
        return running == 0 ? "No timers running" : "\(running) running"
    }

    // MARK: Recents

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recents")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            Divider()
            List {
                ForEach(recents) { recent in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(TimerFormat.string(Double(recent.seconds)))
                                .font(.clock(40, weight: .thin))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(recent.caption)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Start \(recent.caption)", systemImage: "play.fill") {
                            start(seconds: recent.seconds, label: recent.label)
                        }
                        .buttonStyle(.circle(.green, size: 48))
                    }
                    .frame(height: 80)
                    .contentShape(.rect)
                    .onTapGesture { load(recent) }
                    .contextMenu {
                        Button("Start") { start(seconds: recent.seconds, label: recent.label) }
                        Button("Remove") { remove(recent) }
                    }
                    .listRowInsets(.init(top: 0, leading: 28, bottom: 0, trailing: 20))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func load(_ recent: TimersRecent) {
        entry.set([recent.seconds / 3600, (recent.seconds % 3600) / 60, recent.seconds % 60])
        label = recent.label
    }

    private func remove(_ recent: TimersRecent) {
        recentsJSON = TimersRecent.encode(recents.filter { $0 != recent })
    }

    private func record(_ recent: TimersRecent) {
        var list = recents.filter { $0 != recent }
        list.insert(recent, at: 0)
        recentsJSON = TimersRecent.encode(Array(list.prefix(TimersRecent.limit)))
    }

    private func start(seconds: Int, label: String) {
        guard seconds > 0 else { return }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        record(TimersRecent(seconds: seconds, label: trimmed))
        Task {
            var input: [String: JSONValue] = ["seconds": .number(Double(seconds))]
            if !trimmed.isEmpty { input["label"] = .string(trimmed) }
            await model.run("timer.start", .object(input))
        }
    }

    // MARK: Main area

    private var total: Int { entry.values[0] * 3600 + entry.values[1] * 60 + entry.values[2] }

    private func startFromField() {
        start(seconds: total, label: label)
        label = ""
    }

    private func reset() {
        entry.set([0, 0, 0])
        label = ""
    }

    @ViewBuilder
    private var main: some View {
        if active.isEmpty {
            setup
        } else {
            ScrollView {
                VStack(spacing: 28) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16, alignment: .top)], spacing: 32) {
                        ForEach(active) { timer in
                            TimersTile(timer: timer)
                        }
                    }
                    Divider()
                    compactSetup
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
        }
    }

    private var setup: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 14) {
                    DigitField(entry: $entry, labels: ["hr", "min", "sec"], size: min(92, max(40, (geo.size.width - 120) / 3.6)))
                    labelField
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                HStack(spacing: 20) {
                    Button("Cancel", action: reset)
                        .buttonStyle(.pill(width: 160))
                        .disabled(total == 0)
                    Button("Start", action: startFromField)
                        .buttonStyle(.pill(.green, width: 160))
                        .keyboardShortcut(.defaultAction)
                        .disabled(total == 0)
                }
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var labelField: some View {
        TextField("Label", text: $label, prompt: Text("Timer"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 220)
            .onSubmit { if total > 0 { startFromField() } }
    }

    private var compactSetup: some View {
        ViewThatFits {
            HStack(spacing: 16) {
                DigitField(entry: $entry, labels: ["hr", "min", "sec"], size: 40)
                labelField
                Button("Start", action: startFromField)
                    .buttonStyle(.pill(.green, width: 120))
                    .keyboardShortcut(.defaultAction)
                    .disabled(total == 0)
            }
            VStack(spacing: 12) {
                DigitField(entry: $entry, labels: ["hr", "min", "sec"], size: 40)
                HStack(spacing: 12) {
                    labelField
                    Button("Start", action: startFromField)
                        .buttonStyle(.pill(.green, width: 100))
                        .disabled(total == 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tile

private struct TimersTile: View {
    @Environment(AppModel.self) private var model
    let timer: CountdownTimer
    @State private var pulse = false

    private var ringing: Bool { timer.state == .ringing }
    private var paused: Bool { timer.state == .paused }
    private var ringTint: Color { ringing ? .red : (paused ? .gray : .orange) }
    private var id: JSONValue { .string(timer.id.uuidString) }

    private func remaining(at date: Date) -> TimeInterval {
        switch timer.state {
        case .running: max(0, (timer.endsAt ?? date).timeIntervalSince(date))
        case .paused: timer.pausedRemaining ?? timer.duration
        case .ringing, .finished: 0
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if timer.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ring(at: context.date)
                }
            } else {
                ring(at: .now)
            }
            Text(timer.label.isEmpty ? "Timer" : timer.label)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            controls
        }
        .frame(maxWidth: .infinity)
    }

    private func ring(at date: Date) -> some View {
        let left = remaining(at: date)
        let progress = ringing ? 1 : (timer.duration > 0 ? min(1, left / timer.duration) : 0)
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringTint.opacity(ringing && pulse ? 0.45 : 1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(TimerFormat.string(left))
                .font(.clock(44, weight: .light))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 26)
                .foregroundStyle(paused ? .secondary : .primary)
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 190, height: 190)
        .padding(3)
        .onAppear { updatePulse() }
        .onChange(of: ringing) { updatePulse() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timer.label.isEmpty ? "Timer" : timer.label)
        .accessibilityValue(ringing ? "Finished" : TimerFormat.string(left))
    }

    private func updatePulse() {
        if ringing {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.default) { pulse = false }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if ringing {
                Button("Stop") { Task { await model.run("timer.stop", ["id": id]) } }
                    .buttonStyle(.pill(.red, width: 140))
            } else {
                HStack(spacing: 18) {
                    Button("Cancel timer", systemImage: "xmark") {
                        Task { await model.run("timer.cancel", ["id": id]) }
                    }
                    .buttonStyle(.circle(.secondary, size: 48))
                    Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                        Task { await model.run(paused ? "timer.resume" : "timer.pause", ["id": id]) }
                    }
                    .buttonStyle(.circle(paused ? .green : .orange, size: 48))
                }
            }
            Button("+1 min") {
                Task { await model.run("timer.add_time", ["id": id, "seconds": 60]) }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
