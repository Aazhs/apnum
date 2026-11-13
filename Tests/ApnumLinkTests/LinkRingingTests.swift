import ApnumCore
import ApnumLinkCore
import Foundation
import Testing
@testable import ApnumLink

/// Next `ringing` event from the Mac, skipping `changed` events and the like.
private func ringingEvent(_ phone: FakePhone, timeout: Duration = .seconds(3)) async -> JSONValue? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        guard let m = await phone.expect("event", timeout: .milliseconds(300)) else { continue }
        if LinkJSON.string(m["topic"]) == "ringing" { return m["data"] }
    }
    return nil
}

private let alarmItem: JSONValue = [
    "id": "A1", "kind": "alarm", "title": "Wake", "body": "07:30", "canSnooze": true,
]

@Suite struct LinkRingingTests {
    @Test func ringingIsSentRightAfterHelloEvenWhenEmpty() async throws {
        let h = try await Harness()
        await h.link.setRingingProvider { [] }
        let phone = try await h.pair()
        let data = try #require(await ringingEvent(phone))
        #expect(data["items"] == .array([]))
    }

    @Test func ringingChangesAreSentOnceEach() async throws {
        let h = try await Harness()
        let items = LockedBox<[JSONValue]>([])
        await h.link.setRingingProvider { items.get() }
        let phone = try await h.pair()
        _ = await ringingEvent(phone)  // the initial empty set

        items.set([alarmItem])
        h.changes.publish(.ringing)
        let started = try #require(await ringingEvent(phone))
        #expect(started["items"] == .array([alarmItem]))

        h.changes.publish(.ringing)  // same set: nothing new to say
        items.set([])
        h.changes.publish(.ringing)
        let stopped = try #require(await ringingEvent(phone))
        #expect(stopped["items"] == .array([]))
    }

    @Test func phoneRingingIsStored() async throws {
        let h = try await Harness()
        let phone = try await h.pair()
        await phone.send(["t": "event", "topic": "phone.ringing", "data": ["ids": ["A1", "A2"]]])
        await eventually { await h.link.phoneState().ringingIDs.count == 2 }
        #expect(await h.link.phoneState().ringingIDs == ["A1", "A2"])
        await phone.send(["t": "event", "topic": "phone.ringing", "data": ["ids": []]])
        await eventually { await h.link.phoneState().ringingIDs.isEmpty }
        #expect(await h.link.phoneState().ringingIDs.isEmpty)
    }
}
