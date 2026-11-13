import ApnumSky
import Observation
import SwiftUI

/// Sunrise and sunset per day for the sky location, computed once per day and place.
@MainActor @Observable
final class CalDaylightStore {
    struct Day { var sunrise: Date?; var sunset: Date? }
    @ObservationIgnored private var cache: [String: Day] = [:]
    @ObservationIgnored private let engine = SkyEngine()
    var location: GeoLocation?

    func day(_ date: Date) -> Day? {
        guard let location else { return nil }
        let start = Calendar.current.startOfDay(for: date)
        let key = "\(start.timeIntervalSince1970)|\(location.latitude)|\(location.longitude)"
        if let hit = cache[key] { return hit }
        let d = engine.daylight(for: start, location: location)
        let day = Day(sunrise: d.sunrise, sunset: d.sunset)
        cache[key] = day
        return day
    }

    /// "11 h 17 min", or nil when the sun does not rise and set that day.
    func lengthText(_ date: Date) -> String? {
        guard let d = day(date), let r = d.sunrise, let s = d.sunset, s > r else { return nil }
        let minutes = Int((s.timeIntervalSince(r) / 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Night shading for each day column: darker at night, a soft ramp through dawn and dusk,
/// clear in daylight, with dotted sunrise and sunset lines and one pair of labels at the gutter.
struct CalDaylightShade: View {
    @Environment(\.skyTheme) private var theme
    let days: [Date]
    let colW: CGFloat
    let hourHeight: CGFloat
    let gutter: CGFloat
    let store: CalDaylightStore

    private var total: CGFloat { hourHeight * 24 }
    private let ramp: TimeInterval = 50 * 60

    var body: some View {
        let night = theme.isActive ? theme.sidebar : Color.black
        let strength: Double = theme.isActive ? 0.6 : 0.16
        ZStack(alignment: .topLeading) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                if let d = store.day(day), let rise = d.sunrise, let set = d.sunset {
                    let start = Calendar.current.startOfDay(for: day)
                    let f: (Date) -> CGFloat = { CGFloat(min(86_400, max(0, $0.timeIntervalSince(start))) / 86_400) }
                    let stops: [Gradient.Stop] = [
                        .init(color: night.opacity(strength), location: 0),
                        .init(color: night.opacity(strength), location: f(rise.addingTimeInterval(-ramp))),
                        .init(color: night.opacity(0), location: f(rise.addingTimeInterval(ramp))),
                        .init(color: night.opacity(0), location: f(set.addingTimeInterval(-ramp))),
                        .init(color: night.opacity(strength), location: f(set.addingTimeInterval(ramp))),
                        .init(color: night.opacity(strength), location: 1),
                    ]
                    Rectangle()
                        .fill(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
                        .frame(width: colW, height: total)
                        .offset(x: gutter + colW * CGFloat(index))
                    lines(rise: rise, set: set, start: start, index: index)
                }
            }
            labels
        }
        .frame(width: gutter + colW * CGFloat(days.count), height: total, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func y(_ date: Date, start: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 3600) * hourHeight
    }

    private func lines(rise: Date, set: Date, start: Date, index: Int) -> some View {
        Path { p in
            for t in [rise, set] {
                let yy = y(t, start: start)
                p.move(to: CGPoint(x: gutter + colW * CGFloat(index), y: yy))
                p.addLine(to: CGPoint(x: gutter + colW * CGFloat(index + 1), y: yy))
            }
        }
        .stroke(theme.glow.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    /// Labels for one day (today when visible, otherwise the first column), once, at the gutter.
    @ViewBuilder private var labels: some View {
        let reference = days.first { Calendar.current.isDateInToday($0) } ?? days.first
        if let reference, let d = store.day(reference), let rise = d.sunrise, let set = d.sunset {
            let start = Calendar.current.startOfDay(for: reference)
            label("Sunrise", rise, start: start)
            label("Sunset", set, start: start)
        }
    }

    private func label(_ name: String, _ date: Date, start: Date) -> some View {
        Text("\(name) \(ClockFormat.string(date))")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .fixedSize()
            .offset(x: gutter + 4, y: y(date, start: start) - 12)
    }
}
