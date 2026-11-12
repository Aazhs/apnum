import ApnumCore
import ApnumTimers
import SwiftUI

/// The menu bar window: a glance at the day with quick timers.
struct MenuBarGlance: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 14) {
                // A still of the living sky with the time on it.
                ZStack(alignment: .topLeading) {
                    if let scene = model.skyScene {
                        PixelSkyView(scene: scene, animated: false, pixelSize: 2)
                    } else {
                        Rectangle().fill(Sky.day)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ClockText(now, size: 40, weight: .thin)
                        Text(glanceSubtitle(now))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .environment(\.colorScheme, (model.skyScene?.isDark ?? true) ? .dark : .light)
                }
                .frame(height: 150)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))

                DayRibbon(now: now, compact: true)
                    .frame(height: 30)

                ForEach(model.ringing) { RingingBanner(request: $0) }

                let items = model.upcoming(from: now, limit: 4).filter { $0.kind != .timer }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(item.color)
                                    .frame(width: 18)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Text(ClockFormat.string(item.date))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }

                let running = model.timerList.filter { $0.state == .running || $0.state == .paused }
                if !running.isEmpty {
                    Divider()
                    ForEach(running) { GlanceTimerRow(timer: $0) }
                }

                HStack(spacing: 8) {
                    ForEach([1, 5, 10, 25], id: \.self) { minutes in
                        Button("\(minutes) min") {
                            Task { await model.run("timer.start", ["minutes": .number(Double(minutes))]) }
                        }
                        .buttonStyle(.pill(width: 70))
                        .focusEffectDisabled()
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Start a timer")

                HStack(spacing: 8) {
                    Button("Open apnum") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    .buttonStyle(.pill(.accentColor))
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.circle(.secondary, size: 32))
                    .accessibilityLabel("Settings")
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.circle(.secondary, size: 32))
                    .accessibilityLabel("Quit apnum")
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}

extension MenuBarGlance {
    /// "Friday, 13 Nov, Night in Pune".
    func glanceSubtitle(_ now: Date) -> String {
        let date = now.formatted(.dateTime.weekday(.wide).day().month())
        guard let summary = model.skySummary else { return date }
        return "\(date), \(summary.skyName.lowercased()) in \(summary.placeName)"
    }
}

private struct GlanceTimerRow: View {
    @Environment(AppModel.self) private var model
    let timer: CountdownTimer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer").foregroundStyle(.tint)
            Text(timer.label.isEmpty ? "Timer" : timer.label).lineLimit(1)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TimerFormat.string(timer.remaining(at: context.date)))
                    .font(.clock(17, weight: .regular))
                    .monospacedDigit()
            }
            Button {
                let tool = timer.state == .running ? "timer.pause" : "timer.resume"
                Task { await model.run(tool, ["id": .string(timer.id.uuidString)]) }
            } label: {
                Image(systemName: timer.state == .running ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.circle(timer.state == .running ? .orange : .green, size: 28))
            .accessibilityLabel(timer.state == .running ? "Pause" : "Resume")
        }
        .font(.callout)
    }
}
