import ApnumSky
import SwiftUI

// The words and controls that sit on top of the live sky on Today.

/// "Dusk in Pune", the weather, the next sunrise or sunset, the moon, and any
/// rare event in gold. Modelled on the sky clock of aarshj.me.
struct SkyReadout: View {
    let summary: SkySummary
    let scene: SkyScene
    let now: Date

    var body: some View {
        GlassPanel(headline, symbol: symbol) {
            MoonGlyph(phase: scene.moonPhase, fraction: scene.moonFraction)
                .frame(width: 26, height: 26)
                .help("\(summary.moonPhaseName), \(summary.moonPercentLit)% lit")
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text(weatherLine)
                    .font(.title3.weight(.medium))
                if let event = summary.nextSunEvent {
                    Text("\(event.name) \(ClockFormat.relative(to: event.date, from: now)), at \(ClockFormat.string(event.date))")
                        .foregroundStyle(.secondary)
                }
                Text("\(summary.moonPhaseName), \(summary.moonPercentLit)% lit\(summary.moonIsUp ? "" : ", below the horizon")")
                    .foregroundStyle(.secondary)
                ForEach(goldLines, id: \.self) { line in
                    Label(line, systemImage: "sparkles")
                        .foregroundStyle(gold)
                        .font(.callout.weight(.semibold))
                }
            }
        }
    }

    private var headline: String { "\(summary.skyName) in \(summary.placeName)" }

    @Environment(\.colorScheme) private var colorScheme

    private var symbol: String {
        switch summary.skyName {
        case "Night": "moon.stars"
        case "Dawn", "Sunrise": "sunrise"
        case "Dusk", "Sunset": "sunset"
        case "Morning", "Evening": "sun.horizon"
        default: "sun.max"
        }
    }

    /// Gold on dark glass, a deeper amber on light glass so it stays readable.
    private var gold: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.84, blue: 0.48) : Color(red: 0.62, green: 0.38, blue: 0)
    }

    private var weatherLine: String {
        var parts = [summary.weather.kind.label.prefix(1).uppercased() + summary.weather.kind.label.dropFirst()]
        if let t = summary.weather.temperatureC { parts.append("\(Int(t.rounded()))°C") }
        return parts.joined(separator: ", ")
    }

    private var goldLines: [String] {
        var lines = summary.specialEvents
        if let shower = summary.meteorShower { lines.append("\(shower) meteor shower tonight") }
        let planets = scene.planets.filter { $0.position.altitude > 0.05 }.map(\.name)
        if scene.night > 0.3, !planets.isEmpty {
            lines.append(planets.count == 1 ? "\(planets[0]) is up" : "\(planets.dropLast().joined(separator: ", ")) and \(planets.last!) are up")
        }
        return lines
    }
}

/// The moon as it looks tonight: lit side and terminator from the real phase.
struct MoonGlyph: View {
    /// 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
    let phase: Double
    let fraction: Double

    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(disc, with: .color(.white.opacity(0.16)))
            // aarshj.me: a point is lit when its position across the row is past k = cos 2π·phase
            // (right side while waxing, left side while waning).
            let k = cos(2 * .pi * phase)
            let side: CGFloat = phase < 0.5 ? 1 : -1
            let steps = 40
            var lit = Path()
            for i in 0...steps {  // outer limb, top to bottom
                let a = -Double.pi / 2 + Double.pi * Double(i) / Double(steps)
                let p = CGPoint(x: c.x + side * r * cos(a), y: c.y + r * sin(a))
                if i == 0 { lit.move(to: p) } else { lit.addLine(to: p) }
            }
            for i in 0...steps {  // terminator, bottom to top
                let y = r - 2 * r * Double(i) / Double(steps)
                let half = (r * r - y * y).squareRoot()
                lit.addLine(to: CGPoint(x: c.x + side * k * half, y: c.y + y))
            }
            lit.closeSubpath()
            context.fill(lit, with: .color(Color(red: 1, green: 0.96, blue: 0.89)))
            context.stroke(disc, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

extension SkyScene {
    /// An accent colour taken from the sky, for "Tint apnum with the sky":
    /// day blue overhead, the rose or amber of the ridges around sunrise and sunset,
    /// and the moonlit lavender rim at night.
    var accent: Color {
        switch sunAltitudeDegrees {
        case 12...: palette.skyTop.color
        case -10..<12: palette.peak.color
        default: palette.rim.color
        }
    }
}

/// A plain backdrop from the live palette: the sky from zenith to horizon.
/// Used until (and wherever) the animated pixel scene is not shown.
struct SceneBackdrop: View {
    let scene: SkyScene

    var body: some View {
        let p = scene.palette
        LinearGradient(
            stops: [
                .init(color: p.skyTop.color, location: 0), .init(color: p.sky.color, location: 0.38),
                .init(color: p.skyLow.color, location: 0.6), .init(color: p.haze.color, location: 0.74),
                .init(color: p.mid.color, location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.linear(duration: 2), value: p)
            .accessibilityHidden(true)
    }
}
