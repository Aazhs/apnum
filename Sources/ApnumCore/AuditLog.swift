import Foundation

public struct AuditEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case ok, denied, error }

    public var id: UUID { invocationID }
    public let invocationID: UUID
    public let date: Date
    public let tool: String
    public let tier: PermissionTier
    public let caller: String
    public let outcome: Outcome
    public let message: String?
    public let durationMs: Int

    public init(
        invocationID: UUID, date: Date = Date(), tool: String, tier: PermissionTier, caller: String,
        outcome: Outcome, message: String? = nil, durationMs: Int
    ) {
        self.invocationID = invocationID
        self.date = date
        self.tool = tool
        self.tier = tier
        self.caller = caller
        self.outcome = outcome
        self.message = message
        self.durationMs = durationMs
    }
}

/// Records every tool call as one JSON line. Inputs and outputs are never
/// logged, because they can hold private data such as OTPs and messages.
public actor AuditLog {
    private let url: URL?
    private var recentEntries: [AuditEntry] = []
    private let keep: Int

    /// - Parameter url: the JSON-lines file, or nil to keep entries in memory only.
    public init(url: URL?, keepInMemory: Int = 500) {
        self.url = url
        self.keep = keepInMemory
    }

    public func record(_ entry: AuditEntry) {
        recentEntries.append(entry)
        if recentEntries.count > keep { recentEntries.removeFirst(recentEntries.count - keep) }
        guard let url, var line = try? JSONCoding.encoder.encode(entry) else { return }
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
        } catch {
            // Auditing must never break a tool call.
        }
    }

    /// Most recent entries first.
    public func recent(limit: Int = 100) -> [AuditEntry] {
        Array(recentEntries.suffix(limit).reversed())
    }
}
