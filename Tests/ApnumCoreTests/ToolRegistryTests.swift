import Foundation
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

    @Test func changeFeedBroadcasts() async {
        let feed = ChangeFeed()
        let a = feed.subscribe(), b = feed.subscribe()
        feed.publish(.notes)
        var ia = a.makeAsyncIterator(), ib = b.makeAsyncIterator()
        #expect(await ia.next() == .notes)
        #expect(await ib.next() == .notes)
    }
}
