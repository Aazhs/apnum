import ApnumAlarms
import ApnumSky
import SwiftUI

/// How the sky will look at a moment, for alarm rows: palette, caption and whether it is night.
struct ClockSkyMoment {
    let altitude: Double
    let rising: Bool

    var caption: String {
        switch (altitude, rising) {
        case (..<(-6), true): "Before sunrise"
        case (..<(-6), false): "Night"
        case (..<6, true): "At sunrise"
        case (..<6, false): "At sunset"
        case (_, true): "Morning"
        default: "Afternoon"
        }
    }

    /// The sun counts as up from just below the horizon, so a sunrise alarm shows the sun.
    var isDay: Bool { altitude > -1.5 }
    var palette: SkyPalette { .forSky(sunAltitude: altitude) }

    init(altitude: Double, rising: Bool) {
        self.altitude = altitude
        self.rising = rising
    }

    init(at date: Date, location: GeoLocation) {
        let engine = SkyEngine()
        let a = engine.sunAltitudeDegrees(at: date, location: location)
        let b = engine.sunAltitudeDegrees(at: date.addingTimeInterval(600), location: location)
        self.init(altitude: a, rising: b > a)
    }

    /// The next time of day `hour:minute` on one of `days` (any day when empty), after `date`.
    static func nextRing(hour: Int, minute: Int, days: Set<Weekday>, after date: Date = .now) -> Date? {
        let cal = Calendar.current
        var base = DateComponents(hour: hour, minute: minute, second: 0)
        if days.isEmpty { return cal.nextDate(after: date, matching: base, matchingPolicy: .nextTime) }
        return days.compactMap { day -> Date? in
            base.weekday = day.rawValue
            return cal.nextDate(after: date, matching: base, matchingPolicy: .nextTime)
        }.min()
    }
}

/// A small rounded square showing the sky at the moment an alarm will ring.
struct SkyChip: View {
    let moment: ClockSkyMoment
    var dimmed = false
    var moonPhase: Double = 0.5
    var moonFraction: Double = 1
    var size: CGFloat = 44

    var body: some View {
        let p = moment.palette
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [p.skyTop.color, p.haze.color], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                if moment.isDay {
                    // Lower in the sky near the horizon.
                    let y = max(0, min(1, 1 - moment.altitude / 60)) * size * 0.28
                    Circle()
                        .fill(Color(red: 1, green: 0.95, blue: 0.78))
                        .frame(width: size * 0.22, height: size * 0.22)
                        .shadow(color: Color(red: 1, green: 0.85, blue: 0.5).opacity(0.8), radius: 4)
                        .offset(y: y - size * 0.1)
                } else {
                    MoonGlyph(phase: moonPhase, fraction: moonFraction)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .offset(y: -size * 0.05)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
            .saturation(dimmed ? 0.15 : 1)
            .opacity(dimmed ? 0.7 : 1)
            .accessibilityHidden(true)
    }
}
