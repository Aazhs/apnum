import ApnumSky
import SwiftUI

extension View {
    /// Rows of a grouped form sit on the sky theme's panel colour while the theme is active.
    func themedRows(_ theme: SkyTheme) -> some View {
        listRowBackground(theme.isActive ? theme.panel : nil)
    }
}

/// Today's sky from midnight to midnight for a place, with a marker for now and the
/// sunrise and sunset times beneath it.
struct ListSkyDayStrip: View {
    @Environment(\.skyTheme) private var theme
    let location: GeoLocation

    private func fraction(_ date: Date) -> CGFloat {
        let start = Calendar.current.startOfDay(for: .now)
        return CGFloat(min(86_400, max(0, date.timeIntervalSince(start))) / 86_400)
    }

    var body: some View {
        let engine = SkyEngine()
        let colors = engine.dayColors(for: .now, location: location).map(\.color)
        let daylight = engine.daylight(for: .now, location: location)
        let marks = [daylight.sunrise, daylight.sunset].compactMap { $0 }
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    ForEach(marks, id: \.self) { t in
                        Rectangle().fill(.white.opacity(0.5)).frame(width: 1).offset(x: w * fraction(t))
                    }
                    ForEach(0..<5, id: \.self) { i in
                        Text(["0:00", "6:00", "12:00", "18:00", "24:00"][i])
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                            .position(x: min(max(w * CGFloat(i) / 4, 14), w - 14), y: 84)
                    }
                    TimelineView(.everyMinute) { context in
                        ZStack(alignment: .top) {
                            Rectangle().fill(.white).frame(width: 2)
                            Circle().fill(.white).frame(width: 9, height: 9).offset(y: -2)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: w * fraction(context.date) - 1)
                    }
                }
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.edge, lineWidth: 1) }
            }
            .frame(height: 96)
            HStack {
                Label(daylight.sunrise.map { "Sunrise \(ClockFormat.string($0))" } ?? "No sunrise today", systemImage: "sunrise")
                Spacer()
                Text(location.name)
                Spacer()
                Label(daylight.sunset.map { "Sunset \(ClockFormat.string($0))" } ?? "No sunset today", systemImage: "sunset")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
