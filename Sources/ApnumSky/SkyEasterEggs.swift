import Foundation

/// Recognises the Konami sequence (up up down down left right left right B A). A wrong key restarts the
/// match, and a key that is itself the first of the sequence starts a new one, so "up up up down down ..." still works.
public struct KonamiDetector: Sendable, Equatable {
    public enum Key: Sendable, Equatable { case up, down, left, right, b, a }

    public static let sequence: [Key] = [.up, .up, .down, .down, .left, .right, .left, .right, .b, .a]
    public private(set) var progress = 0

    public init() {}

    /// Feeds one key; true when it completes the sequence (the detector then starts over).
    public mutating func feed(_ key: Key) -> Bool {
        let seq = Self.sequence
        if key == seq[progress] {
            progress += 1
        } else {
            progress = key == seq[0] ? (progress == 2 ? 2 : 1) : 0  // "up up up" keeps the two ups
        }
        if progress == seq.count {
            progress = 0
            return true
        }
        return false
    }
}

/// The rare late-night mode: between 2:00 and 3:59 local time, about one launch in 50.
public enum HorrorMode {
    public static let launchChance = 1.0 / 50

    /// `roll` is a uniform 0..<1 number drawn once per launch; `forced` is the test override.
    public static func isActive(now: Date, roll: Double, forced: Bool, calendar: Calendar = .current) -> Bool {
        if forced { return true }
        guard roll < launchChance else { return false }
        let hour = calendar.component(.hour, from: now)
        return hour >= 2 && hour < 4
    }

    /// Short, mild whispers shown in red, one at a time and in order.
    public static let whispers = [
        "...is anyone there?",
        "it is very quiet tonight.",
        "I keep walking. the screen never ends.",
        "every time you close the window, it goes dark.",
        "the lamp is the only warm thing here.",
        "please do not close it yet.",
        "is it morning soon?",
        "someone is waking up. act normal.",
        "Hi! Welcome back :)",
    ]
}
