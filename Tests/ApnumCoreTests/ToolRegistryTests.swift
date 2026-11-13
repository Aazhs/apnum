import Foundation
import Synchronization
import Testing
@testable import ApnumCore

private struct Echo: Tool {
    struct Input: Codable, Sendable { var text: String; var times: Int? }
    struct Output: Codable, Sendable, Equatable { var result: String }
    static let name = "test.echo"
    static let summary = "Repeats text"
    static let tier = PermissionTier.read
    static let inputSchema = Schema.object(["text": .string(), "times": .integer(minimum: 1)], required: ["text"])
    func run(_ input: Input, context: ToolContext) async throws -> Output {
        Output(result: String(repeating: input.text, count: input.times ?? 1))
    }
}

private struct Boom: Tool {
    static let name = "test.boom"
    static let summary = "Always fails"
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.empty
    func run(_ input: Empty, context: ToolContext) async throws -> Ack { throw ToolError.failed("boom") }
}

@Suite struct ToolRegistryTests {
    let audit = AuditLog(url: nil)

    func registry(policy: any PermissionPolicy = DefaultPermissionPolicy()) -> ToolRegistry {
        ToolRegistry(tools: [AnyTool(Echo()), AnyTool(Boom())], policy: policy, audit: audit)
    }

    @Test func typedCall() async throws {
        let out = try await registry().call(Echo.self, .init(text: "ab", times: 2))
        #expect(out == .init(result: "abab"))
    }

    @Test func jsonCall() async throws {
        let out = try await registry().callJSON("test.echo", input: ["text": "x", "times": 3], caller: .agent("claude-code"))
        #expect(out == ["result": "xxx"])
    }

    @Test func invalidInputIsReported() async throws {
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("test.echo", input: ["times": 1], caller: .cli)
        }
    }

    @Test func unknownTool() async throws {
        await #expect(throws: ToolError.notFound("nope")) {
            _ = try await registry().callJSON("nope", caller: .ui)
        }
    }

    @Test func agentsCannotRunDangerousTools() async throws {
        await #expect(throws: ToolError.self) {
            _ = try await registry().callJSON("test.boom", caller: .agent("x"))
        }
        let last = await audit.recent(limit: 1).first
        #expect(last?.outcome == .denied)
        #expect(last?.caller == "agent:x")
    }

    @Test func failuresAreAudited() async throws {
        await #expect(throws: ToolError.failed("boom")) {
            _ = try await registry().call(Boom.self)
        }
        #expect(await audit.recent(limit: 1).first?.outcome == .error)
    }

    @Test func remoteToolsAreListedCalledAuditedAndRemoved() async throws {
        let r = registry()
        let remote = ToolDescriptor(name: "phone.ping", summary: "Pings the phone", tier: .read, inputSchema: Schema.empty.json)
        let clash = ToolDescriptor(name: "test.echo", summary: "Would shadow a local tool", tier: .read, inputSchema: Schema.empty.json)
        r.setRemoteTools(source: "phone", descriptors: [remote, clash]) { tool, input, context in
            ["tool": .string(tool), "caller": .string(context.caller.description), "echo": input]
        }
        #expect(r.descriptors.map(\.name) == ["phone.ping", "test.boom", "test.echo"])
        #expect(r.localDescriptors.map(\.name) == ["test.boom", "test.echo"])
        #expect(r.descriptor(named: "phone.ping")?.summary == "Pings the phone")

        let out = try await r.callJSON("phone.ping", input: ["a": 1], caller: .agent("x"))
        #expect(out["tool"] == "phone.ping")
        #expect(out["caller"] == "agent:x")
        #expect(await audit.recent(limit: 1).first?.tool == "phone.ping")

        // The local tool still answers under its own name.
        #expect(try await r.callJSON("test.echo", input: ["text": "hi"], caller: .ui) == ["result": "hi"])

        r.removeRemoteTools(source: "phone")
        await #expect(throws: ToolError.notFound("phone.ping")) {
            _ = try await r.callJSON("phone.ping", caller: .ui)
        }
    }

    @Test func trustedCallersMayRunDangerousTools() async throws {
        let policy = DefaultPermissionPolicy(trusted: { $0 == .phone("moto") })
        let r = registry(policy: policy)
        await #expect(throws: ToolError.failed("boom")) {  // allowed, so it reaches the tool, which fails
            _ = try await r.callJSON("test.boom", caller: .phone("moto"))
        }
        await #expect(throws: ToolError.self) {
            _ = try await r.callJSON("test.boom", caller: .phone("other"))
        }
        #expect(await audit.recent(limit: 1).first?.outcome == .denied)
    }

    @Test func descriptorsIncludeSchema() {
        let d = registry().descriptor(named: "test.echo")
        #expect(d?.inputSchema["required"] == ["text"])
        #expect(registry().descriptors.map(\.name) == ["test.boom", "test.echo"])
    }
}

@Suite struct CoreUtilityTests {
    @Test func jsonValueRoundTrip() throws {
        let value: JSONValue = ["a": true, "b": 1, "c": [1.5, "s", nil]]
        let data = try JSONCoding.encoder.encode(value)
        #expect(try JSONCoding.decoder.decode(JSONValue.self, from: data) == value)
    }

    @Test func fileStoreRoundTrip() async throws {
        let paths = AppPaths.temporary()
        let store = JSONFileStore<[String: Int]>(url: paths.file("x/y.json"))
        #expect(try await store.load() == nil)
        try await store.save(["a": 1])
        #expect(try await store.load() == ["a": 1])
    }

    @Test func auditLogWritesLines() async throws {
        let paths = AppPaths.temporary()
        let log = AuditLog(url: paths.auditLog)
        for i in 0..<3 {
            await log.record(AuditEntry(invocationID: UUID(), tool: "t\(i)", tier: .read, caller: "ui", outcome: .ok, durationMs: 0))
        }
        let lines = try String(contentsOf: paths.auditLog, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(await log.recent(limit: 1).first?.tool == "t2")
    }

    @Test func wakeSchedulerSleepsUntilDueAndWakesOnPoke() async throws {
        let fires = Mutex(0)
        let due = Mutex<Date?>(nil)
        let scheduler = WakeScheduler(maxSleep: 60)
        scheduler.start(next: { _ in due.withLock { $0 } }, fire: { _ in fires.withLock { $0 += 1 } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fires.withLock { $0 } == 1)  // fired once at start, then sleeping (nothing due)

        due.withLock { $0 = Date().addingTimeInterval(0.2) }
        scheduler.poke()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fires.withLock { $0 } == 2)  // poke re-checked immediately

        due.withLock { $0 = nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fires.withLock { $0 } == 3)  // woke at the due date
        scheduler.stop()
    }

    @Test func changeFeedBroadcasts() async {
        let feed = ChangeFeed()
        let a = feed.subscribe(), b = feed.subscribe()
        feed.publish(.notes)
        var ia = a.makeAsyncIterator(), ib = b.makeAsyncIterator()
        #expect(await ia.next() == .notes)
        #expect(await ib.next() == .notes)
    }
}
