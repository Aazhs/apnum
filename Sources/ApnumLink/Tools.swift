import ApnumCore
import Foundation

extension LinkService {
    /// Every tool this module offers.
    public nonisolated func makeTools() -> [AnyTool] {
        [
            AnyTool(LinkStatusTool(link: self)),
            AnyTool(LinkPairBeginTool(link: self)),
            AnyTool(LinkPairCancelTool(link: self)),
            AnyTool(LinkUnpairTool(link: self)),
            AnyTool(LinkSettingsSetTool(link: self)),
        ]
    }
}

struct LinkStatusTool: Tool {
    let link: LinkService
    struct Output: Codable, Sendable {
        var status: String
        var enabled: Bool
        var autoCopyCodes: Bool
        var syncClipboard: Bool
        var device: PairedDevice?
        var connectedSince: Date?
        var fingerprint: String?
    }
    static let name = "link.status"
    static let summary = "Show whether the paired phone is connected, the paired device, and the link settings."
    static let tier = PermissionTier.read
    static let inputSchema = Schema.empty

    func run(_ input: Empty, context: ToolContext) async throws -> Output {
        let settings = await link.settings()
        let fingerprint = await link.fingerprint()
        switch await link.status() {
        case .off:
            return Output(status: "off", enabled: settings.enabled, autoCopyCodes: settings.autoCopyCodes, syncClipboard: settings.syncClipboard, fingerprint: fingerprint)
        case .notPaired:
            return Output(status: "notPaired", enabled: settings.enabled, autoCopyCodes: settings.autoCopyCodes, syncClipboard: settings.syncClipboard, fingerprint: fingerprint)
        case .waitingForPhone:
            return Output(
                status: "waitingForPhone", enabled: settings.enabled, autoCopyCodes: settings.autoCopyCodes, syncClipboard: settings.syncClipboard,
                device: await link.pairedDevice(), fingerprint: fingerprint)
        case .connected(let device, let since):
            return Output(
                status: "connected", enabled: settings.enabled, autoCopyCodes: settings.autoCopyCodes, syncClipboard: settings.syncClipboard, device: device,
                connectedSince: since, fingerprint: fingerprint)
        }
    }
}

struct LinkPairBeginTool: Tool {
    let link: LinkService
    struct Output: Codable, Sendable {
        var uri: String
        var code: String
        var expiresAt: Date
    }
    static let name = "link.pair.begin"
    static let summary = "Start pairing a phone: returns the pairing link, an 8-digit code and when they expire (5 minutes). Replaces the currently paired phone when a new one completes."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.empty

    func run(_ input: Empty, context: ToolContext) async throws -> Output {
        let offer = try await link.beginPairing()
        return Output(uri: offer.uri, code: offer.code, expiresAt: offer.expiresAt)
    }
}

struct LinkPairCancelTool: Tool {
    let link: LinkService
    static let name = "link.pair.cancel"
    static let summary = "Cancel the pairing in progress."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.empty

    func run(_ input: Empty, context: ToolContext) async throws -> Ack {
        await link.cancelPairing()
        return Ack()
    }
}

struct LinkUnpairTool: Tool {
    let link: LinkService
    static let name = "link.unpair"
    static let summary = "Disconnect and forget the paired phone. It has to be paired again to reconnect."
    static let tier = PermissionTier.dangerous
    static let inputSchema = Schema.empty

    func run(_ input: Empty, context: ToolContext) async throws -> Ack {
        try await link.unpair()
        return Ack()
    }
}

struct LinkSettingsSetTool: Tool {
    let link: LinkService
    struct Input: Decodable, Sendable {
        var enabled: Bool?
        var autoCopyCodes: Bool?
        var syncClipboard: Bool?
        var trustDangerous: Bool?
    }
    static let name = "link.settings.set"
    static let summary = "Change phone link settings: turn the link on or off, copy one-time codes automatically, sync the clipboard with the phone, or allow the phone to run dangerous actions."
    static let tier = PermissionTier.write
    static let inputSchema = Schema.object([
        "enabled": .boolean("Turn the phone link on or off"),
        "autoCopyCodes": .boolean("Copy one-time codes from the phone to the Mac clipboard when they arrive"),
        "syncClipboard": .boolean("Keep the Mac and phone clipboards in sync (plain text only)"),
        "trustDangerous": .boolean("Allow the paired phone to run dangerous Mac actions"),
    ])

    func run(_ input: Input, context: ToolContext) async throws -> Ack {
        if input.trustDangerous != nil, context.caller != .ui, context.caller != .cli {
            throw ToolError.denied("Only the user can change what the phone is allowed to do.")
        }
        if let v = input.autoCopyCodes { try await link.setAutoCopyCodes(v) }
        if let v = input.syncClipboard { try await link.setSyncClipboard(v) }
        if let v = input.trustDangerous { try await link.setTrustDangerous(v) }
        if let v = input.enabled { try await link.setEnabled(v) }
        return Ack()
    }
}
