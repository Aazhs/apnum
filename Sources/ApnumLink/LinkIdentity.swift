import ApnumCore
import ApnumLinkCore
import Foundation
import Security

/// Where this Mac's private link key lives.
public protocol KeyStoring: Sendable {
    func loadPrivateKey() throws -> Data?
    func savePrivateKey(_ key: Data) throws
    func deletePrivateKey() throws
}

/// The Keychain (generic password, service "dev.apnum.mac.link").
public struct KeychainKeyStore: KeyStoring {
    public static let service = "dev.apnum.mac.link"
    private let account: String

    public init(account: String = "static-key") { self.account = account }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func loadPrivateKey() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw ToolError.failed("Keychain read failed (\(status))") }
        return data
    }

    public func savePrivateKey(_ key: Data) throws {
        try? deletePrivateKey()
        var q = query
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ToolError.failed("Keychain write failed (\(status))") }
    }

    public func deletePrivateKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ToolError.failed("Keychain delete failed (\(status))") }
    }
}

/// A plain file under AppPaths. For tests and demo mode, where the Keychain should stay untouched.
public struct FileKeyStore: KeyStoring {
    private let url: URL

    public init(paths: AppPaths) { url = paths.file("link-key.bin") }

    public func loadPrivateKey() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func savePrivateKey(_ key: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func deletePrivateKey() throws { try? FileManager.default.removeItem(at: url) }
}

/// This Mac's identity on the link: a device id, a name and a long-lived static key pair.
public struct LinkIdentity: Sendable {
    public let deviceID: UUID
    public let name: String
    public let privateKey: Data
    public let publicKey: Data

    public var fingerprint: String { ApnumLinkCore.fingerprint(publicKey: publicKey) }

    /// Loads the key from `keys`, creating and saving one on first launch.
    static func load(keys: any KeyStoring, deviceID: UUID, name: String? = nil) throws -> LinkIdentity {
        let privateKey: Data
        if let existing = try keys.loadPrivateKey(), existing.count == 32 {
            privateKey = existing
        } else {
            privateKey = try generateKeypair().privateKey
            try keys.savePrivateKey(privateKey)
        }
        return LinkIdentity(
            deviceID: deviceID, name: name ?? Host.current().localizedName ?? "Mac",
            privateKey: privateKey, publicKey: try publicKeyFor(privateKey: privateKey))
    }
}
