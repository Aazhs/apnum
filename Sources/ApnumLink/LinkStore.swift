import ApnumCore
import ApnumLinkCore
import Foundation

/// The one phone this Mac is paired with.
public struct PairedDevice: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var os: String?
    public var app: String?
    /// The phone's static public key, base64.
    public var publicKey: String
    public var pairedAt: Date
    public var lastSeen: Date?
    /// Whether the phone may run dangerous Mac tools.
    public var trustDangerous: Bool

    public var publicKeyData: Data? { Data(base64Encoded: publicKey) }
    /// The phone's key fingerprint, e.g. "4F2A 91C0 7B3E 55D1".
    public var fingerprint: String? { publicKeyData.map { ApnumLinkCore.fingerprint(publicKey: $0) } }

    public init(
        id: String, name: String, kind: String = "android", os: String? = nil, app: String? = nil, publicKey: String = "",
        pairedAt: Date = Date(), lastSeen: Date? = nil, trustDangerous: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.os = os
        self.app = app
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.trustDangerous = trustDangerous
    }
}

public struct LinkSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var autoCopyCodes = true
    /// Keep the Mac and phone clipboards in step (plain text only).
    public var syncClipboard = true
    public init(enabled: Bool = true, autoCopyCodes: Bool = true, syncClipboard: Bool = true) {
        self.enabled = enabled
        self.autoCopyCodes = autoCopyCodes
        self.syncClipboard = syncClipboard
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoCopyCodes = try c.decodeIfPresent(Bool.self, forKey: .autoCopyCodes) ?? true
        syncClipboard = try c.decodeIfPresent(Bool.self, forKey: .syncClipboard) ?? true
    }
}

struct LinkFile: Codable, Sendable, Equatable {
    var deviceID: UUID
    var device: PairedDevice?
    var settings = LinkSettings()
}

/// link.json: this Mac's device id, the paired phone and the link settings.
actor LinkStore {
    private let store: JSONFileStore<LinkFile>
    private(set) var file: LinkFile

    init(paths: AppPaths) {
        store = JSONFileStore(url: paths.file("link.json"))
        file = LinkFile(deviceID: UUID(), device: nil)
    }

    func load() async throws {
        if let loaded = try await store.load() { file = loaded } else { try await store.save(file) }
    }

    func update(_ change: (inout LinkFile) -> Void) async throws {
        change(&file)
        try await store.save(file)
    }
}
