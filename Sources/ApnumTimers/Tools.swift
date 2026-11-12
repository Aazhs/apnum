import ApnumCore
import Foundation

/// A timer as agents see it.
public struct TimerInfo: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var state: String
    public var durationSeconds: Double
    public var remainingSeconds: Double
    public var remainingText: String
    public var endsAt: Date?

    init(_ t: CountdownTimer, at date: Date) {
        id = t.id.uuidString
        label = t.label
        state = t.state.rawValue
        durationSeconds = t.duration
        remainingSeconds = t.remaining(at: date)
        remainingText = TimerFormat.string(remainingSeconds)
        endsAt = t.endsAt
    }
}

public struct TimerList: Codable, Sendable, Equatable {
    public var timers: [TimerInfo]
}

public struct TimerIDInput: Codable, Sendable {
    public var id: String
}

private let idSchema = Schema.object(
    ["id": .string("Timer id (UUID) from timer.list", format: "uuid")], required: ["id"])

func parseTimerID(_ s: String) throws -> UUID {
    guard let id = UUID(uuidString: s.trimmingCharacters(in: .whitespaces)) else {
        throw ToolError.invalidInput("id must be a UUID string from timer.list, got \"\(s)\".")
    }
    return id
}

struct TimerListTool: Tool {
    let service: TimerService
    static let name = "timer.list"
    static let summary = "List countdown timers with state and remaining seconds."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> TimerList {
        let list = await service.timers()
        let date = service.currentDate
        return TimerList(timers: list.map { TimerInfo($0, at: date) })
    }
}

struct TimerStartTool: Tool {
    struct Input: Codable, Sendable {
        var seconds: Double?
        var minutes: Double?
        var hours: Double?
        var label: String?
    }
    let service: TimerService
    static let name = "timer.start"
    static let summary = "Start a countdown timer; seconds, minutes and hours are added together (1 second to 24 hours)."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "seconds": .number("Seconds to add to the duration"),
        "minutes": .number("Minutes to add to the duration"),
        "hours": .number("Hours to add to the duration"),
        "label": .string("Optional name shown when the timer rings"),
    ])
    func run(_ input: Input, context: ToolContext) async throws -> TimerInfo {
        guard input.seconds != nil || input.minutes != nil || input.hours != nil else {
            throw ToolError.invalidInput("Provide at least one of seconds, minutes or hours.")
        }
        let parts = [input.seconds ?? 0, input.minutes ?? 0, input.hours ?? 0]
        guard parts.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ToolError.invalidInput("seconds, minutes and hours must not be negative.")
        }
        let total = parts[0] + parts[1] * 60 + parts[2] * 3600
        let timer = try await service.start(duration: total, label: input.label ?? "")
        return TimerInfo(timer, at: timer.createdAt)
    }
}

struct TimerPauseTool: Tool {
    let service: TimerService
    static let name = "timer.pause"
    static let summary = "Pause a running timer, keeping its remaining time."
    static let tier = PermissionTier.write
    static let inputSchema = idSchema
    func run(_ input: TimerIDInput, context: ToolContext) async throws -> TimerInfo {
        let t = try await service.pause(id: parseTimerID(input.id))
        return TimerInfo(t, at: service.currentDate)
    }
}

struct TimerResumeTool: Tool {
    let service: TimerService
    static let name = "timer.resume"
    static let summary = "Resume a paused timer."
    static let tier = PermissionTier.write
    static let inputSchema = idSchema
    func run(_ input: TimerIDInput, context: ToolContext) async throws -> TimerInfo {
        let t = try await service.resume(id: parseTimerID(input.id))
        return TimerInfo(t, at: service.currentDate)
    }
}

struct TimerCancelTool: Tool {
    let service: TimerService
    static let name = "timer.cancel"
    static let summary = "Cancel and remove a timer (also silences it if it is ringing)."
    static let tier = PermissionTier.write
    static let inputSchema = idSchema
    func run(_ input: TimerIDInput, context: ToolContext) async throws -> Ack {
        try await service.cancel(id: parseTimerID(input.id))
        return Ack()
    }
}

struct TimerAddTimeTool: Tool {
    struct Input: Codable, Sendable {
        var id: String
        var seconds: Double
    }
    let service: TimerService
    static let name = "timer.add_time"
    static let summary = "Add seconds to a running or paused timer; on a ringing timer, silences it and runs again."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "id": .string("Timer id (UUID) from timer.list", format: "uuid"),
        "seconds": .number("Seconds to add (greater than 0)"),
    ], required: ["id", "seconds"])
    func run(_ input: Input, context: ToolContext) async throws -> TimerInfo {
        let t = try await service.addTime(id: parseTimerID(input.id), seconds: input.seconds)
        return TimerInfo(t, at: service.currentDate)
    }
}

struct TimerStopTool: Tool {
    let service: TimerService
    static let name = "timer.stop"
    static let summary = "Stop a ringing timer's alert and remove the timer."
    static let tier = PermissionTier.write
    static let inputSchema = idSchema
    func run(_ input: TimerIDInput, context: ToolContext) async throws -> Ack {
        try await service.stopRinging(id: parseTimerID(input.id))
        return Ack()
    }
}

public struct StopwatchInfo: Codable, Sendable, Equatable {
    public var running: Bool
    public var elapsedSeconds: Double
    public var elapsedText: String
    /// Cumulative elapsed seconds at each lap.
    public var laps: [Double]

    init(_ s: Stopwatch, at date: Date) {
        running = s.isRunning
        elapsedSeconds = s.elapsed(at: date)
        elapsedText = TimerFormat.string(elapsedSeconds.rounded(.down))
        laps = s.laps
    }
}

struct StopwatchGetTool: Tool {
    let service: TimerService
    static let name = "stopwatch.get"
    static let summary = "Get the stopwatch state: running, elapsed seconds and laps."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> StopwatchInfo {
        StopwatchInfo(await service.stopwatch(), at: service.currentDate)
    }
}

struct StopwatchControlTool: Tool {
    struct Input: Codable, Sendable { var action: String }
    let service: TimerService
    static let name = "stopwatch.control"
    static let summary = "Control the stopwatch: start, pause, lap (while running) or reset (clears time and laps)."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "action": .string("What to do", enumValues: ["start", "pause", "lap", "reset"])
    ], required: ["action"])
    func run(_ input: Input, context: ToolContext) async throws -> StopwatchInfo {
        switch input.action {
        case "start": try await service.stopwatchStart()
        case "pause": try await service.stopwatchPause()
        case "lap":
            guard try await service.stopwatchLap() != nil else {
                throw ToolError.invalidInput("The stopwatch is not running; start it before taking a lap.")
            }
        case "reset": try await service.stopwatchReset()
        default: throw ToolError.invalidInput("action must be one of start, pause, lap, reset.")
        }
        return StopwatchInfo(await service.stopwatch(), at: service.currentDate)
    }
}
