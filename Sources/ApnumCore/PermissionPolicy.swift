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
    public init() {}

    public func decide(_ tool: ToolDescriptor, caller: Caller) async -> PermissionDecision {
        switch caller {
        case .ui, .cli, .system:
            return .allow
        case .agent, .phone:
            return tool.tier < .dangerous
                ? .allow
                : .deny("\(tool.name) needs approval on the Mac, which is not built yet")
        }
    }
}

/// Allows everything. For tests.
public struct AllowAllPolicy: PermissionPolicy {
    public init() {}
    public func decide(_ tool: ToolDescriptor, caller: Caller) async -> PermissionDecision { .allow }
}
