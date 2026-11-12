import ApnumCore
import Foundation

/// Day of the week. Raw values match Foundation `Calendar` weekday numbers.
public enum Weekday: Int, CaseIterable, Sendable, Comparable, Codable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    /// Short name for display ("Mon").
    public var shortName: String { String(clockName.prefix(3)) }

    /// Lowercase name used in tool inputs and stored files ("monday").
    public var wireName: String {
        switch self {
        case .sunday: "sunday"
        case .monday: "monday"
        case .tuesday: "tuesday"
        case .wednesday: "wednesday"
        case .thursday: "thursday"
        case .friday: "friday"
        case .saturday: "saturday"
        }
    }

    /// Capitalised name ("Monday"), as the Clock app shortcut expects.
    public var clockName: String { wireName.prefix(1).uppercased() + wireName.dropFirst() }

    /// Parses "monday", "Mon", "MON" (case-insensitive, full name or three-letter prefix).
    public init?(name: String) {
        let n = name.lowercased()
        guard let match = Weekday.allCases.first(where: { $0.wireName == n || (n.count == 3 && $0.wireName.hasPrefix(n)) })
        else { return nil }
        self = match
    }

    public static func < (a: Weekday, b: Weekday) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            guard let d = Weekday(name: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown weekday \(s)")
            }
            self = d
        } else {
            let i = try c.decode(Int.self)
            guard let d = Weekday(rawValue: i) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown weekday \(i)")
            }
            self = d
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wireName)
    }
}

public struct Alarm: SyncRecord, Equatable {
    public var id: UUID
    /// 0-23
    public var hour: Int
    /// 0-59
    public var minute: Int
    public var label: String
    /// Empty means a one-shot alarm.
    public var repeatDays: Set<Weekday>
    public var isEnabled: Bool
    /// Minutes a snooze lasts; 0 disables snoozing.
    public var snoozeMinutes: Int
    /// System sound name, or nil for the default.
    public var sound: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var snoozedUntil: Date?
    public var lastFiredAt: Date?

    public init(
        id: UUID = UUID(), hour: Int, minute: Int, label: String = "", repeatDays: Set<Weekday> = [],
        isEnabled: Bool = true, snoozeMinutes: Int = 9, sound: String? = nil, createdAt: Date, updatedAt: Date? = nil,
        deletedAt: Date? = nil, snoozedUntil: Date? = nil, lastFiredAt: Date? = nil
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.label = label
        self.repeatDays = repeatDays
        self.isEnabled = isEnabled
        self.snoozeMinutes = snoozeMinutes
        self.sound = sound
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
        self.snoozedUntil = snoozedUntil
        self.lastFiredAt = lastFiredAt
    }

    public var isOneShot: Bool { repeatDays.isEmpty }

    /// "07:30"
    public var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

public struct AlarmSettings: Codable, Sendable, Equatable {
    /// When true the macOS Clock app rings alarms (via a Shortcut), so apnum does not ring them itself.
    public var mirrorToClockApp: Bool

    public init(mirrorToClockApp: Bool = false) { self.mirrorToClockApp = mirrorToClockApp }
}
