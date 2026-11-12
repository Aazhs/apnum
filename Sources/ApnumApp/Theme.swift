import ApnumCore
import SwiftUI

// apnum's design system.
//
// The interface is native macOS: system type, the user's accent colour,
// semantic colours and Liquid Glass for controls that float above content.
// The one signature element is the sky: a gradient that follows the colour
// of the sky through a day. It appears only where time-of-day is the subject
// (the Today ribbon, the menu bar glance and the app icon).

// MARK: - Sky palette

enum Sky {
    /// Sky colours keyed by hour of day, as RGB.
    private static let stops: [(hour: Double, rgb: (Double, Double, Double))] = [
        (0, rgb(0x141B33)), (4.5, rgb(0x2B2D5C)), (6.5, rgb(0xF2A36B)), (9, rgb(0x9CC8F2)), (13, rgb(0x6FAEEB)),
        (16.5, rgb(0x86B4E6)), (18.6, rgb(0xD17FA0)), (20, rgb(0x5B4A96)), (21.5, rgb(0x241F4A)), (24, rgb(0x141B33)),
    ]

    private static func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// The whole day, left to right.
    static var day: LinearGradient {
        LinearGradient(
            stops: stops.map { Gradient.Stop(color: Color(red: $0.rgb.0, green: $0.rgb.1, blue: $0.rgb.2), location: $0.hour / 24) },
            startPoint: .leading, endPoint: .trailing)
    }

    static func hour(of date: Date, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    private static func components(atHour hour: Double) -> (Double, Double, Double) {
        let h = (hour.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
        let upper = stops.firstIndex { $0.hour >= h } ?? stops.count - 1
        let lower = max(upper - 1, 0)
        let a = stops[lower], b = stops[upper]
        let t = b.hour == a.hour ? 0 : (h - a.hour) / (b.hour - a.hour)
        return (a.rgb.0 + (b.rgb.0 - a.rgb.0) * t, a.rgb.1 + (b.rgb.1 - a.rgb.1) * t, a.rgb.2 + (b.rgb.2 - a.rgb.2) * t)
    }

    /// The sky colour at an hour of the day (0-24), blended between stops.
    static func color(atHour hour: Double) -> Color {
        let c = components(atHour: hour)
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    static func color(at date: Date) -> Color { color(atHour: hour(of: date)) }

    /// True when white text reads better than black on the sky.
    static func isDark(atHour hour: Double) -> Bool {
        let c = components(atHour: hour)
        return 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 < 0.5
    }

    /// Darkens a colour towards black (amount 1 = unchanged).
    static func shade(_ color: Color, by amount: Double) -> Color {
        color.mix(with: .black, by: 1 - amount)
    }
}

// MARK: - Type

extension Font {
    /// Rounded numerals for times and durations, like the system Clock app.
    static func clock(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// A time of day in the user's 12- or 24-hour preference, with the AM/PM
/// marker set smaller than the digits.
struct ClockText: View {
    let digits: String
    let marker: String?
    var size: CGFloat = 34
    var weight: Font.Weight = .light

    init(_ date: Date, size: CGFloat = 34, weight: Font.Weight = .light) {
        (digits, marker) = ClockFormat.parts(date)
        self.size = size
        self.weight = weight
    }

    init(hour: Int, minute: Int, size: CGFloat = 34, weight: Font.Weight = .light) {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
        self.init(date, size: size, weight: weight)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.08) {
            Text(digits)
                .font(.clock(size, weight: weight))
                .monospacedDigit()
            if let marker {
                Text(marker)
                    .font(.clock(max(size * 0.36, 11), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum ClockFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    /// ("9:41", "AM") in 12-hour locales, ("21:41", nil) in 24-hour ones.
    static func parts(_ date: Date) -> (String, String?) {
        let text = formatter.string(from: date)
        let pieces = text.split(separator: " ", omittingEmptySubsequences: true)
        if pieces.count == 2, pieces[1].contains(where: \.isLetter) {
            return (String(pieces[0]), String(pieces[1]))
        }
        if pieces.count == 2, pieces[0].contains(where: \.isLetter) {
            return (String(pieces[1]), String(pieces[0]))
        }
        return (text, nil)
    }

    static func string(_ date: Date) -> String { formatter.string(from: date) }

    /// "in 9 h 12 min", "in 4 min", "now".
    static func relative(to date: Date, from now: Date = .now) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        if h >= 24 { return "in \(h / 24) d \(h % 24) h" }
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }
}

// MARK: - Colour helpers

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Shared pieces

/// Read / write / dangerous, as a small tinted capsule.
struct TierBadge: View {
    let tier: PermissionTier

    private var color: Color {
        switch tier {
        case .read: .green
        case .write: .blue
        case .dangerous: .red
        }
    }

    var body: some View {
        Text(tier.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// A section heading inside a page: a short title and optional trailing control.
struct PageHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            trailing
        }
    }
}

/// Floating banner for a ringing alarm or timer, on tinted glass.
struct RingingBanner: View {
    @Environment(AppModel.self) private var model
    let request: RingRequest

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: request.kind == .alarm ? "alarm.waves.left.and.right.fill" : "timer")
                .font(.title)
                .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 1.2)))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.headline).lineLimit(1)
                Text(request.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if request.canSnooze {
                Button("Snooze") { Task { await model.snooze(request) } }
                    .buttonStyle(.pill)
            }
            Button("Stop") { Task { await model.stopRinging(request) } }
                .buttonStyle(.pill(.orange))
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 22))
    }
}
