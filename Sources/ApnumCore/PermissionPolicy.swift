public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny(String)
}

/// Decides whether a caller may run a tool. Later versions will ask the user
/// on the Mac before letting an agent or the phone run a dangerous tool.
public protocol PermissionPolicy: Sendable {
    func decide(_ tool: ToolDescriptor, caller: Caller) async -> PermissionDecision
}

/// The user (UI, CLI) and internal work may run anything.
/// Agents and the phone may read and write, but not run dangerous tools.
public struct DefaultPermissionPolicy: PermissionPolicy {
    private let trusted: (@Sendable (Caller) async -> Bool)?

    /// - Parameter trusted: asked when an agent or phone wants to run a dangerous tool;
    ///   return true if the user has allowed that caller to (for example the paired phone
    ///   with "Allow dangerous actions" turned on).
    public init(trusted: (@Sendable (Caller) async -> Bool)? = nil) {
        self.trusted = trusted
    }

    public func decide(_ tool: ToolDescriptor, caller: Caller) async -> PermissionDecision {
        switch caller {
        case .ui, .cli, .system:
            return .allow
        case .agent, .phone:
            if tool.tier < .dangerous { return .allow }
            if let trusted, await trusted(caller) { return .allow }
            return .deny("\(tool.name) is a dangerous action. Allow it for this device on the Mac first.")
        }
    }
}

/// Allows everything. For tests.
public struct AllowAllPolicy: PermissionPolicy {
    public init() {}
    public func decide(_ tool: ToolDescriptor, caller: Caller) async -> PermissionDecision { .allow }
}
