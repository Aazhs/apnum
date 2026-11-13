import ApnumCore
import Foundation
import Testing
@testable import ApnumLink

@Suite struct LinkPushTests {
    private func sms(id: String = "m1", body: String = "Your code is 482913", otp: String? = "482913") -> JSONValue {
        var data: [String: JSONValue] = ["id": .string(id), "address": "HDFCBK", "body": .string(body), "dateMs": 1_700_000_100_000]
        if let otp { data["otp"] = .string(otp) }
        return .object(data)
    }

    @Test func smsEventUpdatesStateTheMomentItIsProcessed() async throws {
        let h = try await Harness()
        let codes = LockedBox<[PhoneCode]>([])
        await h.link.setOnCode { codes.set(codes.get() + [$0]) }
        await h.link.peerEvent(topic: "sms.received", data: sms())
        // No waiting, no refresh: the very next read already has the message and the code.
        let state = await h.link.phoneState()
        #expect(state.messages.first?.id == "m1")
        #expect(state.latestCode?.code == "482913")
        await eventually { codes.get().count == 1 }
        #expect(codes.get().count == 1)
    }

    @Test func theSameMessageFiresTheCodeHookOnce() async throws {
        let h = try await Harness()
        let codes = LockedBox<[PhoneCode]>([])
        await h.link.setOnCode { codes.set(codes.get() + [$0]) }
        await h.link.peerEvent(topic: "sms.received", data: sms())
        await h.link.peerEvent(topic: "sms.received", data: sms())
        await h.link.peerEvent(topic: "sms.received", data: sms(id: "m2", body: "Another is 111222", otp: "111222"))
        await eventually { codes.get().count >= 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(codes.get().map(\.code) == ["482913", "111222"])
        #expect(Set(await h.link.phoneState().messages.map(\.id)) == ["m1", "m2"])
    }

    @Test func ringEventAndResultDriveFindMyPhone() async throws {
        let h = try await Harness()
        await h.link.peerEvent(topic: "ring", data: ["active": true])
        #expect(await h.link.phoneState().findRinging)
        await h.link.peerEvent(topic: "ring", data: ["active": false])
        #expect(await h.link.phoneState().findRinging == false)
    }

    @Test func clipboardEventsReachTheHookOnlyWhenSyncIsOn() async throws {
        let h = try await Harness()
        let got = LockedBox<[String]>([])
        await h.link.setOnClipboard { got.set(got.get() + [$0]) }
        await h.link.peerEvent(topic: "clipboard", data: ["text": "hello", "id": "a"])
        try await h.link.setSyncClipboard(false)
        await h.link.peerEvent(topic: "clipboard", data: ["text": "nope", "id": "b"])
        #expect(got.get() == ["hello"])
    }

    @Test func addressesYouCanReplyTo() {
        #expect(PhoneNumber.isDialable("+91 98765 43210"))
        #expect(PhoneNumber.isDialable("(555) 123-4567"))
        #expect(PhoneNumber.isDialable("98765"))
        #expect(!PhoneNumber.isDialable("JD-GROWWO-S"))
        #expect(!PhoneNumber.isDialable("HDFCBK"))
        #expect(!PhoneNumber.isDialable("AX-1234"))
        #expect(!PhoneNumber.isDialable(""))
    }

    @Test func clipboardLogicSendsOnlyNewPlainText() {
        var logic = ClipboardSyncLogic(changeCount: 1)
        #expect(logic.observe(changeCount: 1, types: ["public.utf8-plain-text"], text: "same") == nil)
        #expect(logic.observe(changeCount: 2, types: ["public.utf8-plain-text"], text: "hello") == "hello")
        #expect(logic.observe(changeCount: 3, types: ["public.utf8-plain-text"], text: "hello") == nil)
        #expect(logic.observe(changeCount: 4, types: ["public.png"], text: nil) == nil)
        #expect(logic.observe(changeCount: 5, types: [], text: String(repeating: "x", count: 100_001)) == nil)
    }

    @Test func clipboardLogicSkipsConcealedAndTransientItems() {
        var logic = ClipboardSyncLogic(changeCount: 0)
        #expect(logic.observe(changeCount: 1, types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], text: "hunter2") == nil)
        #expect(logic.observe(changeCount: 2, types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"], text: "123456") == nil)
        #expect(logic.forced(types: ["org.nspasteboard.ConcealedType"], text: "hunter2") == nil)
    }

    @Test func clipboardLogicDoesNotEchoWhatItReceived() {
        var logic = ClipboardSyncLogic(changeCount: 0)
        #expect(logic.receive("from phone") == "from phone")
        logic.didWrite(changeCount: 7)
        #expect(logic.observe(changeCount: 7, types: ["public.utf8-plain-text"], text: "from phone") == nil)
        // Even if the change count moved for another reason, the same text is not echoed back.
        #expect(logic.observe(changeCount: 8, types: ["public.utf8-plain-text"], text: "from phone") == nil)
        // The phone echoing our own copy back is ignored too.
        #expect(logic.observe(changeCount: 9, types: [], text: "mine") == "mine")
        #expect(logic.receive("mine") == nil)
        // A new copy is sent, and a manual send works even for repeats.
        #expect(logic.forced(types: [], text: "mine") == "mine")
    }
}
