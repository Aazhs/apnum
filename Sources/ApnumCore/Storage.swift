import Foundation

/// Where apnum keeps its data. Defaults to ~/Library/Application Support/apnum;
/// the APNUM_HOME environment variable overrides it.
public struct AppPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> AppPaths {
        if let home = ProcessInfo.processInfo.environment["APNUM_HOME"], !home.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: home, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appendingPathComponent("apnum", isDirectory: true))
    }

    /// A fresh, empty directory under the system temp folder. For tests.
    public static func temporary() -> AppPaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apnum-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppPaths(root: dir)
    }

    public func file(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: false) }

    /// A subdirectory, created if needed.
    public func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public var auditLog: URL { file("audit.jsonl") }
}

/// Stores one Codable value as a pretty-printed JSON file, written atomically.
public actor JSONFileStore<Value: Codable & Sendable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The stored value, or nil if the file does not exist yet.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONCoding.decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.prettyEncoder.encode(value).write(to: url, options: .atomic)
    }
}

/// Fields every synced record carries, so the Mac and phone can merge edits
/// later (last write wins on `updatedAt`; deletes are kept as tombstones).
public protocol SyncRecord: Codable, Sendable, Identifiable where ID == UUID {
    var id: UUID { get }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
}

public extension SyncRecord {
    var isDeleted: Bool { deletedAt != nil }
}
