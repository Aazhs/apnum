import Foundation

/// How much harm a tool can do. Used by `PermissionPolicy` to decide
/// whether a caller (UI, agent, phone) may run it without approval.
public enum PermissionTier: String, Codable, Sendable, Comparable, CaseIterable {
    /// Reads data only.
    case read
    /// Changes local state (create an alarm, edit a note).
    case write
    /// Acts outward or is hard to undo (send a message, run a shortcut, sleep the Mac).
    case dangerous

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// Who is calling a tool.
public enum Caller: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    /// The Mac app's own interface.
    case ui
    /// A command-line client on this Mac.
    case cli
    /// Internal work, such as the alarm scheduler.
    case system
    /// An AI agent, identified by name (for example "claude-code").
    case agent(String)
    /// A paired phone, identified by device name.
    case phone(String)

    public var description: String {
        switch self {
        case .ui: "ui"
        case .cli: "cli"
        case .system: "system"
        case .agent(let n): "agent:\(n)"
        case .phone(let n): "phone:\(n)"
        }
    }
}

/// Passed to every tool invocation.
public struct ToolContext: Sendable {
    public let invocationID: UUID
    public let caller: Caller
    public init(invocationID: UUID = UUID(), caller: Caller) {
        self.invocationID = invocationID
        self.caller = caller
    }
}

/// One capability of apnum, callable by the UI, agents and the phone alike.
///
/// Conventions:
/// - `name` is `domain.verb` or `domain.noun.verb`, lowercase, e.g. `alarm.create`, `mac.volume.set`.
/// - `inputSchema` must describe `Input` exactly; agents read it.
/// - Inputs and outputs are plain Codable structs. Dates are ISO-8601 strings on the wire.
/// - Throw `ToolError` for expected failures; other errors are wrapped as `.failed`.
public protocol Tool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    static var name: String { get }
    static var summary: String { get }
    static var tier: PermissionTier { get }
    static var inputSchema: Schema { get }

    func run(_ input: Input, context: ToolContext) async throws -> Output
}

/// Input for tools that take no arguments. Encodes as `{}`; the registry
/// also accepts `null` for it.
public struct Empty: Codable, Sendable, Equatable {
    public init() {}
}

/// Output for tools that only need to report success.
public struct Ack: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    public init(ok: Bool = true, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

/// Metadata describing a registered tool, as shown to agents.
public struct ToolDescriptor: Sendable, Equatable, Codable {
    public let name: String
    public let summary: String
    public let tier: PermissionTier
    public let inputSchema: JSONValue
}

public enum ToolError: Error, Sendable, Equatable, LocalizedError {
    case notFound(String)
    case invalidInput(String)
    case denied(String)
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let s): "No such tool or item: \(s)"
        case .invalidInput(let s): "Invalid input: \(s)"
        case .denied(let s): "Not allowed: \(s)"
        case .unavailable(let s): "Unavailable: \(s)"
        case .failed(let s): s
        }
    }
}
