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
    @Environment(\.skyTheme) private var theme

    private var watch: Stopwatch { model.stopwatch }

    private var laps: [StopwatchLap] {
        watch.laps.enumerated().map { index, total in
            StopwatchLap(number: index + 1, split: total - (index > 0 ? watch.laps[index - 1] : 0), total: total)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // With no laps, centre the stopwatch in the window like the Clock app.
            if watch.laps.isEmpty && !watch.isRunning { Spacer(minLength: 0) }
            VStack(spacing: 22) {
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
            .padding(.top, 28)
            .padding(.bottom, 24)
            .padding(.horizontal, 28)

            lapList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.isActive ? theme.background : Color.clear)
        .navigationTitle("Stopwatch")
    }

    private var startTitle: String {
        if watch.isRunning { return "Stop" }
        return watch.accumulated > 0 ? "Resume" : "Start"
    }

    private var dialSize: CGFloat { watch.laps.isEmpty ? 320 : 220 }

    /// The dial with the digital time beneath it. Only animates while running.
    @ViewBuilder
    private var readout: some View {
        if watch.isRunning {
            TimelineView(.animation) { context in
                face(elapsed: watch.elapsed(at: context.date))
            }
        } else {
            face(elapsed: watch.accumulated)
        }
    }

    private func face(elapsed: TimeInterval) -> some View {
        VStack(spacing: watch.laps.isEmpty ? 18 : 10) {
            StopwatchDial(
                elapsed: elapsed, lapElapsed: elapsed - (watch.laps.last ?? 0), showsLapHand: !watch.laps.isEmpty || watch.isRunning,
                theme: theme
            )
            .frame(width: dialSize, height: dialSize)
            digits(elapsed)
        }
    }

    private func digits(_ seconds: TimeInterval) -> some View {
        Text(stopwatchText(seconds))
            .font(.clock(watch.laps.isEmpty ? 72 : 56, weight: .thin))
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets)
                }
                ForEach(done.reversed()) { lap in
                    let color: Color? = !colored ? nil : (lap.split == fastest ? .green : (lap.split == slowest ? .red : nil))
                    lapRow("Lap \(lap.number)", split: lap.split, total: lap.total, color: color)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowInsets)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var rowInsets: EdgeInsets { .init(top: 3, leading: 12, bottom: 3, trailing: 12) }

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
        .padding(.horizontal, 16)
        .frame(height: 40)
        .skyPanel(theme, cornerRadius: 12)
    }

    private func control(_ action: String) {
        Task { await model.run("stopwatch.control", ["action": .string(action)]) }
    }
}

// MARK: - Dial

/// An analog stopwatch face: 60 ticks, a seconds hand in the accent colour and a small lap hand.
private struct StopwatchDial: View {
    let elapsed: TimeInterval
    let lapElapsed: TimeInterval
    let showsLapHand: Bool
    let theme: SkyTheme

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 2
            let accent = theme.isActive ? theme.accent : Color.accentColor
            let tick = theme.isActive ? theme.edge : Color.secondary.opacity(0.5)
            let strong = theme.isActive ? Color.white.opacity(0.55) : Color.secondary

            func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: c.x + radius * CGFloat(sin(angle)), y: c.y - radius * CGFloat(cos(angle)))
            }

            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(disc, with: .color(theme.isActive ? theme.panel.opacity(0.55) : Color.primary.opacity(0.04)))
            context.stroke(disc, with: .color(theme.isActive ? theme.edge : Color.primary.opacity(0.12)), lineWidth: 1.5)

            for i in 0..<60 {
                let a = Double(i) / 60 * 2 * .pi
                let major = i % 5 == 0
                var p = Path()
                p.move(to: point(a, r - 8))
                p.addLine(to: point(a, r - (major ? 20 : 14)))
                context.stroke(p, with: .color(major ? strong : tick), style: StrokeStyle(lineWidth: major ? 2 : 1, lineCap: .round))
            }
            for n in stride(from: 10, through: 60, by: 10) {
                let a = Double(n) / 60 * 2 * .pi
                let text = Text("\(n)").font(.system(size: r * 0.1, weight: .light)).foregroundStyle(Color.secondary)
                context.draw(context.resolve(text), at: point(a, r - 36))
            }

            if showsLapHand {
                // Small sub-dial for the current lap.
                let sub = CGPoint(x: c.x, y: c.y + r * 0.36)
                let sr = r * 0.2
                context.stroke(Path(ellipseIn: CGRect(x: sub.x - sr, y: sub.y - sr, width: 2 * sr, height: 2 * sr)), with: .color(tick), lineWidth: 1)
                let la = (lapElapsed.truncatingRemainder(dividingBy: 60)) / 60 * 2 * .pi
                var lap = Path()
                lap.move(to: sub)
                lap.addLine(to: CGPoint(x: sub.x + (sr - 3) * CGFloat(sin(la)), y: sub.y - (sr - 3) * CGFloat(cos(la))))
                context.stroke(lap, with: .color(theme.isActive ? theme.glow : Color.secondary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            let a = (elapsed.truncatingRemainder(dividingBy: 60)) / 60 * 2 * .pi
            var hand = Path()
            hand.move(to: point(a + .pi, r * 0.14))
            hand.addLine(to: point(a, r - 12))
            context.stroke(hand, with: .color(accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(accent))
            context.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(theme.isActive ? theme.background : Color(nsColor: .windowBackgroundColor)))
        }
        .accessibilityHidden(true)
    }
}
