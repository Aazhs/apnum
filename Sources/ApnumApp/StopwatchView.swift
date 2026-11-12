import ApnumCore
import ApnumTimers
import SwiftUI

/// "00:07.31", "12:03.90", "1:02:03.00".
private func stopwatchText(_ seconds: TimeInterval) -> String {
    let t = max(0, Int((seconds * 100).rounded(.down)))
    let h = t / 360_000, m = (t / 6000) % 60, s = (t / 100) % 60, c = t % 100
    return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, c) : String(format: "%02d:%02d.%02d", m, s, c)
}

private struct StopwatchLap: Identifiable {
    let number: Int
    let split: TimeInterval
    let total: TimeInterval
    var id: Int { number }
}

struct StopwatchView: View {
    @Environment(AppModel.self) private var model

    private var watch: Stopwatch { model.stopwatch }

    private var laps: [StopwatchLap] {
        watch.laps.enumerated().map { index, total in
            StopwatchLap(number: index + 1, split: total - (index > 0 ? watch.laps[index - 1] : 0), total: total)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 26) {
                readout
                HStack(spacing: 20) {
                    Button(watch.isRunning ? "Lap" : "Reset") { control(watch.isRunning ? "lap" : "reset") }
                        .buttonStyle(.pill(width: 160))
                        .disabled(!watch.isRunning && watch.accumulated == 0)
                    Button(startTitle) { control(watch.isRunning ? "pause" : "start") }
                        .buttonStyle(.pill(watch.isRunning ? .red : .green, width: 160))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 36)
            .padding(.bottom, 24)
            .padding(.horizontal, 28)

            lapList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Stopwatch")
    }

    private var startTitle: String {
        if watch.isRunning { return "Stop" }
        return watch.accumulated > 0 ? "Resume" : "Start"
    }

    @ViewBuilder
    private var readout: some View {
        if watch.isRunning {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                digits(watch.elapsed(at: context.date))
            }
        } else {
            digits(watch.accumulated)
        }
    }

    private func digits(_ seconds: TimeInterval) -> some View {
        Text(stopwatchText(seconds))
            .font(.clock(96, weight: .thin))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityLabel("Elapsed time")
    }

    // MARK: Laps

    @ViewBuilder
    private var lapList: some View {
        let done = laps
        if done.isEmpty && !watch.isRunning {
            Spacer(minLength: 0)
        } else {
            let colored = done.count >= 3
            let fastest = done.map(\.split).min(), slowest = done.map(\.split).max()
            List {
                if watch.isRunning {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let elapsed = watch.elapsed(at: context.date)
                        lapRow("Lap \(done.count + 1)", split: elapsed - (watch.laps.last ?? 0), total: nil, color: nil)
                    }
                }
                ForEach(done.reversed()) { lap in
                    let color: Color? = !colored ? nil : (lap.split == fastest ? .green : (lap.split == slowest ? .red : nil))
                    lapRow("Lap \(lap.number)", split: lap.split, total: lap.total, color: color)
                }
            }
            .listStyle(.plain)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func lapRow(_ title: String, split: TimeInterval, total: TimeInterval?, color: Color?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(stopwatchText(split))
                .frame(width: 120, alignment: .trailing)
            Text(total.map(stopwatchText) ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
        }
        .font(.title3)
        .monospacedDigit()
        .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
        .frame(height: 38)
    }

    private func control(_ action: String) {
        Task { await model.run("stopwatch.control", ["action": .string(action)]) }
    }
}
