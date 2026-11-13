import ApnumCore
import Foundation
import Synchronization
import Testing
@testable import ApnumNotes

private let base = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

private func record(
    _ id: UUID = UUID(), title: String = "T", body: String = "body", updated: TimeInterval = 0, deleted: TimeInterval? = nil
) -> Note {
    Note(id: id, title: title, body: body, tags: ["a", "b"], pinned: false, createdAt: at(-100), updatedAt: at(updated), deletedAt: deleted.map(at))
}

private final class Counter: Sendable {
    let notes = Mutex(0)
    init(_ feed: ChangeFeed) {
        let stream = feed.subscribe()
        Task { [self] in
            for await topic in stream where topic == .notes { self.notes.withLock { $0 += 1 } }
        }
    }
    func count() async -> Int {
        try? await Task.sleep(for: .milliseconds(80))
        return notes.withLock { $0 }
    }
}

@Suite struct NoteSyncTests {
    private func make() async throws -> (NoteService, AppPaths, ChangeFeed) {
        let paths = AppPaths.temporary()
        let feed = ChangeFeed()
        let service = NoteService(paths: paths, changes: feed, now: { at(1000) })
        try await service.load()
        return (service, paths, feed)
    }

    private func file(_ paths: AppPaths, _ id: UUID) throws -> String {
        try String(contentsOf: paths.directory("notes").appendingPathComponent("\(id.uuidString).md"), encoding: .utf8)
    }

    @Test func newRecordsAreWrittenToDisk() async throws {
        let (service, paths, _) = try await make()
        let n = record(title: "Groceries", body: "- milk\n")
        let r = try await service.sync(records: [n])
        #expect(r.records == [n])
        #expect(r.serverTime == at(1000))
        #expect(try file(paths, n.id).contains("title: Groceries"))
        // A fresh service reads it back from disk.
        let again = NoteService(paths: paths, changes: ChangeFeed())
        try await again.load()
        #expect(await again.note(id: n.id) == n)
    }

    @Test func newerWinsOlderLosesTieGoesToIncoming() async throws {
        let (service, paths, _) = try await make()
        let id = UUID()
        _ = try await service.sync(records: [record(id, title: "v1", updated: 10)])
        _ = try await service.sync(records: [record(id, title: "v2", updated: 20)])
        #expect(await service.note(id: id)?.title == "v2")
        _ = try await service.sync(records: [record(id, title: "old", updated: 5)])
        #expect(await service.note(id: id)?.title == "v2")
        #expect(try file(paths, id).contains("title: v2"))
        _ = try await service.sync(records: [record(id, title: "tie", updated: 20)])
        #expect(await service.note(id: id)?.title == "tie")
        #expect(try file(paths, id).contains("title: tie"))
    }

    @Test func tombstonesPropagateBothWays() async throws {
        let (service, paths, _) = try await make()
        let id = UUID()
        _ = try await service.sync(records: [record(id, updated: 10)])
        let r = try await service.sync(records: [record(id, updated: 20, deleted: 20)])
        #expect(r.records.first?.deletedAt == at(20))
        #expect(try file(paths, id).contains("deleted:"))
        #expect(await service.notes().isEmpty)
        // Mac deletes, phone learns through `since`.
        let other = try await service.create(title: "x")
        _ = try await service.delete(id: other.id)
        let r2 = try await service.sync(records: [], since: at(500))
        #expect(r2.records.map(\.id) == [other.id])
        #expect(r2.records[0].deletedAt != nil)
    }

    @Test func sinceFilters() async throws {
        let (service, _, _) = try await make()
        let (a, b) = (UUID(), UUID())
        _ = try await service.sync(records: [record(a, updated: 10), record(b, updated: 50)])
        #expect(try await service.sync(records: [], since: at(10)).records.map(\.id) == [b])
        #expect(try await service.sync(records: [], since: at(50)).records.isEmpty)
        #expect(try await service.sync(records: []).records.count == 2)
    }

    @Test func oneNotesPublishPerBatchAndNoneWhenUnchanged() async throws {
        let (service, _, feed) = try await make()
        let a = record(updated: 10)
        _ = try await service.sync(records: [a])
        let counter = Counter(feed)
        _ = try await service.sync(records: [a, record(a.id, title: "stale", updated: 1)])
        #expect(await counter.count() == 0)
        _ = try await service.sync(records: [record(a.id, title: "new", updated: 11), record(), record()])
        #expect(await counter.count() == 1)
    }

    @Test func syncToolRoundTripsRealJSON() async throws {
        let (service, paths, _) = try await make()
        let registry = ToolRegistry(tools: service.makeTools(), policy: DefaultPermissionPolicy(), audit: AuditLog(url: nil))
        let id = UUID()
        let input: JSONValue = [
            "records": [
                [
                    "id": .string(id.uuidString), "title": "Plan", "body": "# Plan\n- one", "tags": ["work", "home"], "pinned": true,
                    "createdAt": "2026-01-01T06:00:00Z", "updatedAt": "2026-01-02T06:00:00Z",
                ],
                ["id": "nope"],
            ],
            "since": "2026-01-01T00:00:00Z",
        ]
        let out = try await registry.callJSON("note.sync", input: input, caller: .phone("Pixel"))
        #expect(out["skipped"] == 1)
        guard case .array(let records)? = out["records"] else { Issue.record("no records"); return }
        #expect(records.count == 1)
        let rec = records[0]
        #expect(rec["title"] == "Plan" && rec["pinned"] == true && rec["tags"] == ["work", "home"])
        #expect(rec["updatedAt"] == "2026-01-02T06:00:00Z" && rec["deletedAt"] == nil)
        guard case .string? = out["serverTime"] else { Issue.record("no serverTime"); return }
        print("NOTE-JSON:", String(data: try JSONCoding.encoder.encode(rec), encoding: .utf8)!)
        #expect(try file(paths, id).contains("title: Plan"))
    }
}
