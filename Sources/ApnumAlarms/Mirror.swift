import ApnumCore
import Foundation

/// Copies apnum's enabled alarms somewhere else (the macOS Clock app).
public protocol AlarmMirror: Sendable {
    /// Replaces the mirrored alarms with exactly these.
    func sync(_ alarms: [Alarm]) async throws
}

/// Mirrors alarms into the Clock app by running one user-installed shortcut.
/// The shortcut deletes every Clock alarm whose label contains "[apnum]" and
/// adds the ones it is given, so syncing is idempotent and needs no stored IDs.
/// See docs/clock-shortcuts.md.
public struct ClockAppMirror: AlarmMirror {
    public static let shortcutName = "apnum Sync Alarms"
    public static let labelTag = "[apnum]"

    private let runner: any ShortcutRunning

    public init(runner: any ShortcutRunning) { self.runner = runner }

    struct Payload: Codable, Equatable {
        struct Item: Codable, Equatable {
            var hour: Int
            var minute: Int
            var label: String
            var repeatDays: [String]
        }
        var alarms: [Item]
    }

    static func payload(for alarms: [Alarm]) -> Payload {
        Payload(alarms: alarms.map { a in
            let base = a.label.isEmpty ? "Alarm" : a.label
            let label = base.hasSuffix(labelTag) ? base : "\(base) \(labelTag)"
            return .init(hour: a.hour, minute: a.minute, label: label, repeatDays: a.repeatDays.sorted().map(\.clockName))
        })
    }

    public func sync(_ alarms: [Alarm]) async throws {
        guard try await runner.list().contains(Self.shortcutName) else {
            throw ToolError.unavailable(
                "The shortcut \"\(Self.shortcutName)\" is not installed. Create it by following docs/clock-shortcuts.md.")
        }
        let data = try JSONCoding.encoder.encode(Self.payload(for: alarms))
        _ = try await runner.run(Self.shortcutName, input: data)
    }
}
