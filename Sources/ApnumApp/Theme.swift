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
    static let midnight = Color(hex: "#141B33")!
    static let predawn = Color(hex: "#2B2D5C")!
    static let dawn = Color(hex: "#F2A36B")!
    static let morning = Color(hex: "#9CC8F2")!
    static let noon = Color(hex: "#6FAEEB")!
    static let afternoon = Color(hex: "#86B4E6")!
    static let dusk = Color(hex: "#D17FA0")!
    static let twilight = Color(hex: "#5B4A96")!
    static let night = Color(hex: "#241F4A")!

    /// Stops keyed by hour of day.
    static let stops: [(hour: Double, color: Color)] = [
        (0, midnight), (4.5, predawn), (6.5, dawn), (9, morning), (13, noon),
        (16.5, afternoon), (18.6, dusk), (20, twilight), (21.5, night), (24, midnight),
    ]

    /// The whole day, left to right.
    static var day: LinearGradient {
        LinearGradient(
            stops: stops.map { Gradient.Stop(color: $0.color, location: $0.hour / 24) },
            startPoint: .leading, endPoint: .trailing)
    }

    /// The sky colour nearest to a given time.
    static func color(at date: Date, calendar: Calendar = .current) -> Color {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return stops.min { abs($0.hour - hour) < abs($1.hour - hour) }!.color
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
                    .buttonStyle(.glass)
            }
            Button("Stop") { Task { await model.stopRinging(request) } }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 22))
    }
}
