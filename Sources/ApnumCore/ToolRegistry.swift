import Foundation
import Synchronization

/// A type-erased tool, so feature modules can hand the registry a list.
public struct AnyTool: Sendable {
    public let descriptor: ToolDescriptor
    let base: any Sendable
    let runJSON: @Sendable (JSONValue, ToolContext) async throws -> JSONValue

    public init<T: Tool>(_ tool: T) {
        descriptor = ToolDescriptor(name: T.name, summary: T.summary, tier: T.tier, inputSchema: T.inputSchema.json)
        base = tool
        runJSON = { input, context in
            let normalized: JSONValue = input == .null ? .object([:]) : input
            let typed: T.Input
            do { typed = try normalized.decode(T.Input.self) } catch {
                throw ToolError.invalidInput(String(describing: error))
            }
            return try JSONValue(encoding: try await tool.run(typed, context: context))
        }
    }
}

/// The single entry point for every action in apnum. The UI, agents and the
/// phone all call tools through here, so permissions and auditing apply equally.
public final class ToolRegistry: Sendable {
    private let tools: [String: AnyTool]
    private let policy: any PermissionPolicy
    private let audit: AuditLog?

    /// Runs a tool that lives on another device (the paired phone).
    public typealias RemoteHandler = @Sendable (_ tool: String, _ input: JSONValue, _ context: ToolContext) async throws -> JSONValue

    private struct RemoteSource {
        var descriptors: [String: ToolDescriptor]
        var handler: RemoteHandler
    }

    private let remotes = Mutex<[String: RemoteSource]>([:])

    public init(tools: [AnyTool], policy: any PermissionPolicy = DefaultPermissionPolicy(), audit: AuditLog? = nil) {
        var map: [String: AnyTool] = [:]
        for tool in tools {
            precondition(map[tool.descriptor.name] == nil, "Duplicate tool name \(tool.descriptor.name)")
            map[tool.descriptor.name] = tool
        }
        self.tools = map
        self.policy = policy
        self.audit = audit
    }

    /// Every tool that can be called right now, local and remote, sorted by name.
    public var descriptors: [ToolDescriptor] {
        let remote = remotes.withLock { $0.values.flatMap { $0.descriptors.values } }
        return (tools.values.map(\.descriptor) + remote).sorted { $0.name < $1.name }
    }

    /// Only the tools that run on this Mac (what the phone is told about).
    public var localDescriptors: [ToolDescriptor] { tools.values.map(\.descriptor).sorted { $0.name < $1.name } }

    public func descriptor(named name: String) -> ToolDescriptor? {
        tools[name]?.descriptor ?? remotes.withLock { sources in sources.values.lazy.compactMap { $0.descriptors[name] }.first }
    }

    /// Adds (or replaces) the tools offered by a remote source such as the paired phone.
    /// Names that collide with a local tool are ignored: local tools always win.
    public func setRemoteTools(source: String, descriptors: [ToolDescriptor], handler: @escaping RemoteHandler) {
        let usable = descriptors.filter { tools[$0.name] == nil }
        let map = Dictionary(usable.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        remotes.withLock { $0[source] = RemoteSource(descriptors: map, handler: handler) }
    }

    /// Removes a remote source's tools (when the phone disconnects).
    public func removeRemoteTools(source: String) {
        remotes.withLock { _ = $0.removeValue(forKey: source) }
    }

    /// Typed call, used by the Mac UI.
    public func call<T: Tool>(_ type: T.Type, _ input: T.Input, caller: Caller = .ui) async throws -> T.Output {
        guard let entry = tools[T.name], let tool = entry.base as? T else { throw ToolError.notFound(T.name) }
        return try await perform(entry.descriptor, caller: caller) { context in
            try await tool.run(input, context: context)
        }
    }

    /// Typed call for tools without input.
    public func call<T: Tool>(_ type: T.Type, caller: Caller = .ui) async throws -> T.Output where T.Input == Empty {
        try await call(type, Empty(), caller: caller)
    }

    /// JSON call, used by agents, the phone and the CLI.
    public func callJSON(_ name: String, input: JSONValue = .null, caller: Caller) async throws -> JSONValue {
        if let entry = tools[name] {
            return try await perform(entry.descriptor, caller: caller) { context in
                try await entry.runJSON(input, context)
            }
        }
        let remote = remotes.withLock { sources -> (ToolDescriptor, RemoteHandler)? in
            for source in sources.values {
                if let descriptor = source.descriptors[name] { return (descriptor, source.handler) }
            }
            return nil
        }
        guard let (descriptor, handler) = remote else { throw ToolError.notFound(name) }
        return try await perform(descriptor, caller: caller) { context in
            try await handler(name, input == .null ? .object([:]) : input, context)
        }
    }

    private func perform<R: Sendable>(
        _ descriptor: ToolDescriptor, caller: Caller, _ body: (ToolContext) async throws -> R
    ) async throws -> R {
        let context = ToolContext(caller: caller)
        let started = ContinuousClock.now
        func record(_ outcome: AuditEntry.Outcome, _ message: String? = nil) async {
            let elapsed = ContinuousClock.now - started
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            await audit?.record(AuditEntry(
                invocationID: context.invocationID, tool: descriptor.name, tier: descriptor.tier,
                caller: caller.description, outcome: outcome, message: message, durationMs: ms))
        }

        if case .deny(let reason) = await policy.decide(descriptor, caller: caller) {
            await record(.denied, reason)
            throw ToolError.denied(reason)
        }
        do {
            let result = try await body(context)
            await record(.ok)
            return result
        } catch let error as ToolError {
            await record(.error, error.localizedDescription)
            throw error
        } catch {
            await record(.error, error.localizedDescription)
            throw ToolError.failed(error.localizedDescription)
        }
    }
}
