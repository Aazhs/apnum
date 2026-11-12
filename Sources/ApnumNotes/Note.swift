import ApnumCore
import Foundation

/// A Markdown note. Syncs with the phone as a `SyncRecord`.
public struct Note: SyncRecord, Equatable {
    public var id: UUID
    public var title: String
    /// Markdown text.
    public var body: String
    public var tags: [String]
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), title: String = "", body: String = "", tags: [String] = [], pinned: Bool = false,
        createdAt: Date, updatedAt: Date? = nil, deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    /// The title, or the first meaningful body line without heading markers, or "Untitled".
    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        for line in body.split(whereSeparator: \.isNewline) {
            let s = Note.stripHeading(String(line))
            if !s.isEmpty { return s }
        }
        return "Untitled"
    }

    /// About the first 120 characters of the body, without heading markers, on one line.
    public var preview: String {
        var parts: [String] = []
        var count = 0
        for line in body.split(whereSeparator: \.isNewline) {
            let s = Note.stripHeading(String(line)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if s.isEmpty { continue }
            parts.append(s)
            count += s.count + 1
            if count > 130 { break }
        }
        let joined = parts.joined(separator: " ")
        return joined.count > 120 ? String(joined.prefix(120)) + "…" : joined
    }

    static func stripHeading(_ line: String) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.first == "#" {
            let rest = s.drop(while: { $0 == "#" })
            if rest.isEmpty || rest.first == " " || rest.first == "\t" { s = rest }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
