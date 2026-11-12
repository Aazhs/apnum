import ApnumCore
import Foundation

/// An alarm as agents see it.
public struct AlarmInfo: Codable, Sendable, Equatable {
    public var id: String
    public var time: String
    public var hour: Int
    public var minute: Int
    public var label: String
    public var repeatDays: [String]
    public var isEnabled: Bool
    public var snoozeMinutes: Int
    public var sound: String?
    public var nextFireDate: Date?
    public var isRinging: Bool
}

private extension AlarmService {
    func info(_ a: Alarm, now: Date = Date()) -> AlarmInfo {
        let ringingNow = ringing().contains { $0.id == a.id.uuidString }
        return AlarmInfo(
            id: a.id.uuidString, time: a.timeText, hour: a.hour, minute: a.minute, label: a.label,
            repeatDays: a.repeatDays.sorted().map(\.wireName), isEnabled: a.isEnabled, snoozeMinutes: a.snoozeMinutes,
            sound: a.sound, nextFireDate: nextFireDate(for: a, after: now), isRinging: ringingNow)
    }
}

private func parseID(_ s: String) throws -> UUID {
    guard let id = UUID(uuidString: s) else {
        throw ToolError.invalidInput("id must be a UUID string as returned by alarm.list, got \"\(s)\"")
    }
    return id
}

private func parseDays(_ names: [String]) throws -> Set<Weekday> {
    var out: Set<Weekday> = []
    for n in names {
        guard let d = Weekday(name: n) else {
            throw ToolError.invalidInput("Unknown weekday \"\(n)\". Use \(Weekday.allCases.map(\.wireName).joined(separator: ", ")).")
        }
        out.insert(d)
    }
    return out
}

private let dayNames = Weekday.allCases.map(\.wireName)
private let idSchema = Schema.string("Alarm id (UUID) from alarm.list", format: "uuid")

struct AlarmListTool: Tool {
    let service: AlarmService
    struct Output: Codable, Sendable, Equatable { var alarms: [AlarmInfo] }
    static let name = "alarm.list"
    static let summary = "List all alarms with their time, repeat days, enabled state and next ring time."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Output {
        let now = Date()
        var out: [AlarmInfo] = []
        for a in await service.alarms() { out.append(await service.info(a, now: now)) }
        return Output(alarms: out)
    }
}

struct AlarmNextTool: Tool {
    let service: AlarmService
    struct Output: Codable, Sendable, Equatable { var alarm: AlarmInfo? }
    static let name = "alarm.next"
    static let summary = "Get the alarm that will ring next (the alarm field is omitted if none is enabled)."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Output {
        let now = Date()
        guard let next = await service.nextAlarm(after: now) else { return Output(alarm: nil) }
        return Output(alarm: await service.info(next.alarm, now: now))
    }
}

struct AlarmCreateTool: Tool {
    let service: AlarmService
    struct Input: Codable, Sendable {
        var hour: Int
        var minute: Int
        var label: String?
        var repeatDays: [String]?
        var snoozeMinutes: Int?
        var sound: String?
    }
    static let name = "alarm.create"
    static let summary = "Create an alarm at hour:minute (24-hour). Leave repeatDays empty for a one-time alarm."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "hour": .integer("Hour, 0-23", minimum: 0, maximum: 23),
        "minute": .integer("Minute, 0-59", minimum: 0, maximum: 59),
        "label": .string("Shown when the alarm rings"),
        "repeatDays": .array(of: .string(enumValues: dayNames), description: "Weekdays to repeat on; empty or omitted = one time"),
        "snoozeMinutes": .integer("Snooze length in minutes, 0-180; 0 disables snooze (default 9)", minimum: 0, maximum: 180),
        "sound": .string("macOS system sound name, e.g. Glass; omit for the default"),
    ], required: ["hour", "minute"])
    func run(_ input: Input, context: ToolContext) async throws -> AlarmInfo {
        let days = try parseDays(input.repeatDays ?? [])
        let a = try await service.create(
            hour: input.hour, minute: input.minute, label: input.label ?? "", repeatDays: days,
            snoozeMinutes: input.snoozeMinutes ?? 9, sound: input.sound)
        return await service.info(a)
    }
}

struct AlarmUpdateTool: Tool {
    let service: AlarmService
    struct Input: Codable, Sendable {
        var id: String
        var hour: Int?
        var minute: Int?
        var label: String?
        var repeatDays: [String]?
        var isEnabled: Bool?
        var snoozeMinutes: Int?
        var sound: String?
    }
    static let name = "alarm.update"
    static let summary = "Change an alarm's time, label, repeat days, snooze or sound, or enable/disable it. Omitted fields stay as they are."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "id": idSchema,
        "hour": .integer("Hour, 0-23", minimum: 0, maximum: 23),
        "minute": .integer("Minute, 0-59", minimum: 0, maximum: 59),
        "label": .string("New label"),
        "repeatDays": .array(of: .string(enumValues: dayNames), description: "Replaces the repeat days; empty array = one time"),
        "isEnabled": .boolean("false turns the alarm off, true turns it on"),
        "snoozeMinutes": .integer("Snooze length in minutes, 0-180; 0 disables snooze", minimum: 0, maximum: 180),
        "sound": .string("System sound name; empty string restores the default"),
    ], required: ["id"])
    func run(_ input: Input, context: ToolContext) async throws -> AlarmInfo {
        let id = try parseID(input.id)
        let days = try input.repeatDays.map(parseDays)
        let a = try await service.update(
            id: id, hour: input.hour, minute: input.minute, label: input.label, repeatDays: days,
            isEnabled: input.isEnabled, snoozeMinutes: input.snoozeMinutes, sound: input.sound)
        return await service.info(a)
    }
}

struct IDInput: Codable, Sendable { var id: String }

struct AlarmDeleteTool: Tool {
    let service: AlarmService
    static let name = "alarm.delete"
    static let summary = "Delete an alarm."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object(["id": idSchema], required: ["id"])
    func run(_ input: IDInput, context: ToolContext) async throws -> Ack {
        try await service.delete(id: parseID(input.id))
        return Ack()
    }
}

struct AlarmStopTool: Tool {
    let service: AlarmService
    static let name = "alarm.stop"
    static let summary = "Stop a ringing alarm. A one-time alarm turns off afterwards."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object(["id": idSchema], required: ["id"])
    func run(_ input: IDInput, context: ToolContext) async throws -> Ack {
        try await service.stopRinging(id: parseID(input.id))
        return Ack()
    }
}

struct AlarmSnoozeTool: Tool {
    let service: AlarmService
    static let name = "alarm.snooze"
    static let summary = "Silence a ringing alarm and ring again after its snooze length."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object(["id": idSchema], required: ["id"])
    func run(_ input: IDInput, context: ToolContext) async throws -> Ack {
        try await service.snooze(id: parseID(input.id))
        return Ack()
    }
}

struct AlarmMirrorSyncTool: Tool {
    let service: AlarmService
    static let name = "alarm.mirror.sync"
    static let summary = "Re-copy the enabled alarms into the macOS Clock app now; reports the error if the sync failed."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Ack {
        if let error = await service.syncMirrorNow() { return Ack(ok: false, message: error) }
        return Ack()
    }
}
