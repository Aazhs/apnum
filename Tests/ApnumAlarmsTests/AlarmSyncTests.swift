import ApnumCore
import Foundation
import Synchronization
import Testing
@testable import ApnumAlarms

private let base = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

private func record(
    _ id: UUID = UUID(), hour: Int = 7, minute: Int = 30, label: String = "Wake", updated: TimeInterval = 0,
    deleted: TimeInterval? = nil, snooze: Int = 9
) -> Alarm {
    Alarm(
        id: id, hour: hour, minute: minute, label: label, repeatDays: [.monday, .friday], snoozeMinutes: snooze, createdAt: at(-100),
        updatedAt: at(updated), deletedAt: deleted.map(at))
}

/// Counts what the feed publishes.
private final class Counter: Sendable {
    let counts = Mutex<[String: Int]>([:])
    init(_ feed: ChangeFeed) {
        let stream = feed.subscribe()
        Task { [self] in
            for await topic in stream { self.counts.withLock { $0[topic.rawValue, default: 0] += 1 } }
        }
    }
    func count(_ topic: String) async -> Int {
        try? await Task.sleep(for: .milliseconds(80))
        return counts.withLock { $0[topic] ?? 0 }
    }
}

@Suite struct AlarmSyncTests {
    private func fixture() async throws -> Fixture {
        let f = Fixture(start: at(1000))
        try await f.service.load()
        return f
    }

    @Test func newRecordsAreAddedAndEchoed() async throws {
        let f = try await fixture()
        let a = record()
        let r = try await f.service.sync(records: [a])
        #expect(r.records == [a])
        #expect(r.serverTime == at(1000))
        #expect(await f.service.alarms() == [a])
    }

    @Test func newerIncomingWins() async throws {
        let f = try await fixture()
        let id = UUID()
        _ = try await f.service.sync(records: [record(id, label: "old", updated: 10)])
        let r = try await f.service.sync(records: [record(id, hour: 8, label: "new", updated: 20)])
        #expect(r.records.map(\.label) == ["new"])
        #expect(await f.service.alarm(id: id)?.hour == 8)
    }

    @Test func olderIncomingLoses() async throws {
        let f = try await fixture()
        let id = UUID()
        _ = try await f.service.sync(records: [record(id, label: "mac", updated: 20)])
        let r = try await f.service.sync(records: [record(id, label: "phone", updated: 10)])
        #expect(r.records.first?.label == "mac")
        #expect(await f.service.alarm(id: id)?.label == "mac")
    }

    @Test func tieGoesToTheIncomingRecord() async throws {
        let f = try await fixture()
        let id = UUID()
        _ = try await f.service.sync(records: [record(id, label: "mac", updated: 10)])
        _ = try await f.service.sync(records: [record(id, label: "phone", updated: 10)])
        #expect(await f.service.alarm(id: id)?.label == "phone")
    }

    @Test func tombstonesPropagateBothWays() async throws {
        let f = try await fixture()
        let id = UUID()
        // Phone deletes an alarm the Mac has.
        _ = try await f.service.sync(records: [record(id, updated: 10)])
        let r = try await f.service.sync(records: [record(id, updated: 20, deleted: 20)])
        #expect(r.records.first?.deletedAt == at(20))
        #expect(await f.service.alarms().isEmpty)  // alarm.list keeps hiding tombstones
        // A later phone copy of a deleted alarm (edited after the delete) revives it.
        _ = try await f.service.sync(records: [record(id, updated: 30)])
        #expect(await f.service.alarm(id: id) != nil)
        // The Mac deletes; the phone learns of it through `since`.
        try await f.service.delete(id: id)
        let r2 = try await f.service.sync(records: [], since: at(30))
        #expect(r2.records.count == 1 && r2.records[0].deletedAt == at(1000))
    }

    @Test func sinceFiltersTheReply() async throws {
        let f = try await fixture()
        let (a, b) = (UUID(), UUID())
        _ = try await f.service.sync(records: [record(a, updated: 10), record(b, updated: 50)])
        #expect(try await f.service.sync(records: [], since: at(10)).records.map(\.id) == [b])
        #expect(try await f.service.sync(records: [], since: at(50)).records.isEmpty)
        #expect(try await f.service.sync(records: []).records.count == 2)
    }

    @Test func invalidRecordsAreSkipped() async throws {
        let f = try await fixture()
        let r = try await f.service.sync(records: [
            record(hour: 24), record(minute: 60), record(hour: -1), record(snooze: 181), record(label: "ok"),
        ])
        #expect(r.skipped == 4)
        #expect(r.records.map(\.label) == ["ok"])
    }

    @Test func perDeviceFieldsStayOnTheMac() async throws {
        let f = try await fixture()
        var mac = record(updated: 10)
        mac.snoozedUntil = at(5000)
        mac.lastFiredAt = at(900)
        _ = try await f.service.sync(records: [mac])  // incoming values for them are ignored
        #expect(await f.service.alarms().first?.snoozedUntil == nil)
        // Give the Mac real per-device state, then let the phone overwrite the alarm.
        let created = try await f.service.create(hour: 6, minute: 0)
        try await f.service.snooze(id: created.id)
        let before = try #require(await f.service.alarm(id: created.id))
        #expect(before.snoozedUntil != nil)
        var incoming = before
        incoming.label = "from phone"
        incoming.updatedAt = before.updatedAt.addingTimeInterval(5)
        incoming.snoozedUntil = at(1)
        incoming.lastFiredAt = at(2)
        let r = try await f.service.sync(records: [incoming])
        let after = try #require(await f.service.alarm(id: created.id))
        #expect(after.label == "from phone")
        #expect(after.snoozedUntil == before.snoozedUntil)
        #expect(after.lastFiredAt == before.lastFiredAt)
        #expect(r.records.allSatisfy { $0.snoozedUntil == nil && $0.lastFiredAt == nil })
    }

    @Test func nothingChangedMeansNoPublishAndNoMirror() async throws {
        let mirror = FakeMirror()
        let f = Fixture(mirror: mirror, start: at(1000))
        try await f.service.load()
        try await f.service.setSettings(AlarmSettings(mirrorToClockApp: true))
        let a = record(updated: 10)
        _ = try await f.service.sync(records: [a])
        let counter = Counter(f.feed)
        let syncs = mirror.syncs.withLock { $0.count }
        _ = try await f.service.sync(records: [a, record(a.id, label: "stale", updated: 5)])  // identical + older
        #expect(await counter.count("alarms") == 0)
        #expect(mirror.syncs.withLock { $0.count } == syncs)
        _ = try await f.service.sync(records: [record(a.id, label: "changed", updated: 11), record(updated: 1)])
        #expect(await counter.count("alarms") == 1)  // one publish for the whole batch
        #expect(mirror.syncs.withLock { $0.count } == syncs + 1)
    }

    @Test func syncToolRoundTripsRealJSON() async throws {
        let f = try await fixture()
        let registry = ToolRegistry(tools: f.service.makeTools(), policy: DefaultPermissionPolicy(), audit: AuditLog(url: nil))
        let id = UUID()
        let input: JSONValue = [
            "records": [
                [
                    "id": .string(id.uuidString), "hour": 7, "minute": 30, "label": "Gym", "repeatDays": ["monday", "friday"],
                    "isEnabled": true, "snoozeMinutes": 9, "createdAt": "2026-01-01T06:00:00Z", "updatedAt": "2026-01-02T06:00:00Z",
                ],
                ["id": "not-a-uuid", "hour": 1],
                [
                    "id": .string(UUID().uuidString), "hour": 99, "minute": 0, "label": "", "repeatDays": [], "isEnabled": true,
                    "snoozeMinutes": 9, "createdAt": "2026-01-01T06:00:00Z", "updatedAt": "2026-01-02T06:00:00Z",
                ],
            ],
            "since": "2026-01-01T00:00:00Z",
        ]
        let out = try await registry.callJSON("alarm.sync", input: input, caller: .phone("Pixel"))
        #expect(out["skipped"] == 2)
        guard case .array(let records)? = out["records"] else { Issue.record("no records"); return }
        #expect(records.count == 1)
        let rec = records[0]
        #expect(rec["id"] == .string(id.uuidString))
        #expect(rec["updatedAt"] == "2026-01-02T06:00:00Z")
        #expect(rec["label"] == "Gym" && rec["isEnabled"] == true)
        #expect(rec["deletedAt"] == nil && rec["snoozedUntil"] == nil)
        guard case .string? = out["serverTime"] else { Issue.record("no serverTime"); return }
        print("ALARM-JSON:", String(data: try JSONCoding.encoder.encode(rec), encoding: .utf8)!)
        #expect(await f.service.alarms().count == 1)

        // Tombstone through the tool, then list hides it.
        let gone: JSONValue = [
            "records": [
                [
                    "id": .string(id.uuidString), "hour": 7, "minute": 30, "label": "Gym", "repeatDays": [], "isEnabled": true,
                    "snoozeMinutes": 9, "createdAt": "2026-01-01T06:00:00Z", "updatedAt": "2026-01-03T06:00:00Z",
                    "deletedAt": "2026-01-03T06:00:00Z",
                ]
            ]
        ]
        let out2 = try await registry.callJSON("alarm.sync", input: gone, caller: .phone("Pixel"))
        guard case .array(let r2)? = out2["records"] else { Issue.record("no records"); return }
        #expect(r2.first?["deletedAt"] == "2026-01-03T06:00:00Z")
        let list = try await registry.callJSON("alarm.list", input: .null, caller: .phone("Pixel"))
        #expect(list["alarms"] == .array([]))
    }
}
