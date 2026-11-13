import ApnumCore
import ApnumLink
import Foundation

/// The phone link as the UI sees it: snapshots of the link service plus the actions behind the Phone screen.
extension AppModel {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Starts the link (not in demo mode, unless APNUM_LINK=1) and wires its code hook.
    func startLink() async {
        if phoneDemo {
            showDemoPhone()
            return
        }
        await link.attach(registry: registry)
        await link.setOnCode { [weak self] code in await self?.received(code: code) }
        do { try await link.load() } catch { report(error) }
        if !isDemo || environment["APNUM_LINK"] == "1" {
            do { try await link.start() } catch { report(error) }
        }
        await refreshLink()
        if environment["APNUM_LINK_AUTOPAIR"] == "1", case .notPaired = linkStatus {
            // Debug only: lets an end-to-end test find the pairing link without a screen.
            await beginPairing()
            if let uri = pairingOffer?.uri {
                try? Data((uri + "\n").utf8).write(to: paths.file("pairing-uri.txt"), options: .atomic)
            }
        }
    }

    func refreshLink() async {
        if phoneDemo { return }
        linkStatus = await link.status()
        linkSettings = await link.settings()
        pairedDevice = await link.pairedDevice()
        linkFingerprint = await link.fingerprint()
        phone = await link.phoneState()
        pairingSafety = await link.pairingSafetyNumber()
        if case .connected = linkStatus { pairingOffer = nil }
        if let offer = pairingOffer, offer.expiresAt < Date(), pairingSafety == nil { pairingOffer = nil }
        tools = registry.descriptors
    }

    /// Opens a pairing: a QR code and an 8-digit code, good for five minutes.
    func beginPairing() async {
        guard let out = await run("link.pair.begin"), let uri = LinkText.string(out["uri"]), let code = LinkText.string(out["code"]) else { return }
        let expires = LinkText.string(out["expiresAt"]).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date().addingTimeInterval(300)
        pairingOffer = PairingOffer(uri: uri, code: code, expiresAt: expires, fingerprint: linkFingerprint ?? "")
        await refreshLink()
    }

    func cancelPairing() async {
        await run("link.pair.cancel")
        pairingOffer = nil
        await refreshLink()
    }

    func unpairPhone() async {
        await run("link.unpair")
        pairingOffer = nil
        await refreshLink()
    }

    func setLink(enabled: Bool? = nil, autoCopyCodes: Bool? = nil, trustDangerous: Bool? = nil) async {
        var input: [String: JSONValue] = [:]
        if let enabled { input["enabled"] = .bool(enabled) }
        if let autoCopyCodes { input["autoCopyCodes"] = .bool(autoCopyCodes) }
        if let trustDangerous { input["trustDangerous"] = .bool(trustDangerous) }
        await run("link.settings.set", .object(input))
        await refreshLink()
    }

    /// Fetches battery, messages, notifications and call state from the phone again.
    func refreshPhone() async {
        guard !phoneDemo else { return }
        await link.refreshPhone()
        await refreshLink()
    }

    /// Messages with one number, newest first (the whole conversation, not just the recent list).
    func phoneThread(address: String) async -> [PhoneSMS] {
        if phoneDemo || !tools.contains(where: { $0.name == "phone.sms.list" }) {
            return phone.messages.filter { $0.address == address }
        }
        guard let out = await run("phone.sms.list", ["address": .string(address), "limit": 50]) else {
            return phone.messages.filter { $0.address == address }
        }
        return LinkService.parseMessages(out)
    }

    func hasTool(_ name: String) -> Bool { phoneDemo || tools.contains { $0.name == name } }

    /// Sends the Mac clipboard text to the phone.
    func sendClipboardToPhone() async {
        guard let text = LinkText.string(await run("mac.clipboard.get")?["text"]), !text.isEmpty else { return }
        await run("phone.clipboard.set", ["text": .string(text)])
    }

    /// Copies the phone's clipboard text onto the Mac.
    func getPhoneClipboard() async {
        guard let out = await run("phone.clipboard.get") else { return }
        let text = LinkText.string(out) ?? LinkText.string(out["text"])
        if let text, !text.isEmpty { await run("mac.clipboard.set", ["text": .string(text)]) }
    }

    func copyToClipboard(_ text: String) async {
        await run("mac.clipboard.set", ["text": .string(text)])
    }

    private func received(code: PhoneCode) async {
        try? await ringer.notify(title: "Code \(code.code)", body: "From \(code.from)")
        if linkSettings.autoCopyCodes {
            _ = try? await registry.callJSON("mac.clipboard.set", input: ["text": .string(code.code)], caller: .system)
        }
    }

    // MARK: Demo

    private func showDemoPhone() {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let device = PairedDevice(
            id: "demo-phone", name: "moto g86 power", kind: "android", os: "Android 16", app: "0.1.0",
            pairedAt: ago(60 * 24 * 9), lastSeen: now)
        linkStatus = .connected(device: device, since: ago(42))
        pairedDevice = device
        linkSettings = LinkSettings()
        linkFingerprint = "4F2A 91C0 7B3E 55D1"
        var state = PhoneState()
        state.battery = 78
        state.charging = false
        state.info = ["model": "moto g86 power", "network": "Home Wi-Fi"]
        state.messages = [
            PhoneSMS(id: "1", address: "HDFCBK", body: "482913 is your one-time password for a card payment of Rs 1,249.00 at Swiggy. Do not share it with anyone.", date: ago(3)),
            PhoneSMS(id: "2", address: "+91 98765 43210", contactName: "Meera", body: "Reaching the station in ten, can you grab the tickets?", date: ago(18)),
            PhoneSMS(id: "3", address: "+91 98765 43210", contactName: "Meera", body: "Sure, I will be at the counter.", date: ago(24), incoming: false),
            PhoneSMS(id: "4", address: "+91 98765 43210", contactName: "Meera", body: "Did you book the scooter for Goa?", date: ago(31)),
            PhoneSMS(id: "5", address: "Amazon", body: "Your package with the camera strap is out for delivery today.", date: ago(95)),
            PhoneSMS(id: "6", address: "+91 91234 56780", contactName: "Dad", body: "Call me when you are free.", date: ago(60 * 5)),
            PhoneSMS(id: "7", address: "JIOINF", body: "You have used 82% of today's data.", date: ago(60 * 7)),
        ]
        state.notifications = [
            PhoneNotification(key: "n1", app: "WhatsApp", title: "Meera", text: "Sent you the station photo", posted: ago(6)),
            PhoneNotification(key: "n2", app: "Calendar", title: "Dentist at 5:30 PM", text: "Dr Rao, 2nd floor", posted: ago(22)),
            PhoneNotification(key: "n3", app: "Gmail", title: "Your receipt from Third Wave Coffee", text: "Thanks for your order of two flat whites", posted: ago(54)),
        ]
        state.latestCode = PhoneCode(code: "482913", from: "HDFCBK", date: ago(3))
        phone = state
        let phoneTools: [JSONValue] = [
            ["name": "phone.sms.send", "summary": "Send an SMS.", "tier": "dangerous", "inputSchema": [:]],
            ["name": "phone.call.dial", "summary": "Start a phone call.", "tier": "dangerous", "inputSchema": [:]],
        ]
        tools = registry.descriptors + phoneTools.compactMap { try? $0.decode(ToolDescriptor.self) }
    }
}

private enum LinkText {
    static func string(_ value: JSONValue?) -> String? { if case .string(let s)? = value { return s } else { return nil } }
}
