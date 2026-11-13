import ApnumCore
import Foundation

public extension NoteService {
    /// Every note tool, for the registry.
    nonisolated func makeTools() -> [AnyTool] {
        [
            AnyTool(NoteListTool(service: self)),
            AnyTool(NoteGetTool(service: self)),
            AnyTool(NoteCreateTool(service: self)),
            AnyTool(NoteUpdateTool(service: self)),
            AnyTool(NoteAppendTool(service: self)),
            AnyTool(NoteDeleteTool(service: self)),
            AnyTool(NoteRestoreTool(service: self)),
            AnyTool(NoteTagsTool(service: self)),
            AnyTool(NoteSyncTool(service: self)),
        ]
    }
}

/// A note without its full body, for lists.
public struct NoteSummary: Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var preview: String
    public var tags: [String]
    public var pinned: Bool
    public var updatedAt: Date

    init(_ note: Note) {
        id = note.id
        title = note.displayTitle
        preview = note.preview
        tags = note.tags
        pinned = note.pinned
        updatedAt = note.updatedAt
    }
}

private func parseID(_ raw: String) throws -> UUID {
    guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
        throw ToolError.invalidInput("id must be a note UUID such as 6F1C2B9E-0000-4000-8000-000000000000; got \"\(raw)\". Use note.list to find ids.")
    }
    return id
}

private let idSchema = Schema.string("The note's id (UUID) from note.list", format: "uuid")

public struct NoteListTool: Tool {
    public struct Input: Codable, Sendable {
        public var query: String?
        public var tag: String?
        public var limit: Int?
        public init(query: String? = nil, tag: String? = nil, limit: Int? = nil) { self.query = query; self.tag = tag; self.limit = limit }
    }
    public struct Output: Codable, Sendable, Equatable {
        public var notes: [NoteSummary]
        public var total: Int
    }
    public static let name = "note.list"
    public static let summary = "List or search notes (pinned first, then newest) as short summaries; use note.get for the full text."
    public static let tier = PermissionTier.read
    public static let inputSchema = Schema.object([
        "query": .string("Words that must all appear in the title, body or tags (case and accents ignored)"),
        "tag": .string("Only notes with this tag"),
        "limit": .integer("Maximum notes to return, default 50", minimum: 1, maximum: 500),
    ])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Output {
        let limit = input.limit ?? 50
        guard limit >= 1 else { throw ToolError.invalidInput("limit must be at least 1") }
        let all = await service.notes(query: input.query, tag: input.tag)
        return Output(notes: all.prefix(limit).map(NoteSummary.init), total: all.count)
    }
}

public struct NoteGetTool: Tool {
    public struct Input: Codable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }
    public static let name = "note.get"
    public static let summary = "Get one note with its full Markdown body."
    public static let tier = PermissionTier.read
    public static let inputSchema = Schema.object(["id": idSchema], required: ["id"])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Note {
        let id = try parseID(input.id)
        guard let note = await service.note(id: id), !note.isDeleted else {
            throw ToolError.notFound("No note with id \(id.uuidString). Use note.list to find note ids.")
        }
        return note
    }
}

public struct NoteCreateTool: Tool {
    public struct Input: Codable, Sendable {
        public var title: String?
        public var body: String?
        public var tags: [String]?
        public var pinned: Bool?
        public init(title: String? = nil, body: String? = nil, tags: [String]? = nil, pinned: Bool? = nil) {
            self.title = title; self.body = body; self.tags = tags; self.pinned = pinned
        }
    }
    public static let name = "note.create"
    public static let summary = "Create a note with an optional title, Markdown body, tags and pinned flag."
    public static let tier = PermissionTier.write
    public static let inputSchema = Schema.object([
        "title": .string("Title; if empty the first line of the body is shown instead"),
        "body": .string("Markdown text"),
        "tags": .array(of: .string(), description: "Tags, e.g. [\"home\", \"errands\"]"),
        "pinned": .boolean("Keep at the top of the list"),
    ])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Note {
        let title = input.title ?? ""
        let body = input.body ?? ""
        guard !title.isEmpty || !body.isEmpty else {
            throw ToolError.invalidInput("Give the note a title or a body.")
        }
        return try await service.create(title: title, body: body, tags: input.tags ?? [], pinned: input.pinned ?? false)
    }
}

public struct NoteUpdateTool: Tool {
    public struct Input: Codable, Sendable {
        public var id: String
        public var title: String?
        public var body: String?
        public var tags: [String]?
        public var pinned: Bool?
        public init(id: String, title: String? = nil, body: String? = nil, tags: [String]? = nil, pinned: Bool? = nil) {
            self.id = id; self.title = title; self.body = body; self.tags = tags; self.pinned = pinned
        }
    }
    public static let name = "note.update"
    public static let summary = "Change a note's title, body, tags or pinned flag; omitted fields stay as they are. Body replaces the whole text (use note.append to add to it)."
    public static let tier = PermissionTier.write
    public static let inputSchema = Schema.object([
        "id": idSchema,
        "title": .string("New title"),
        "body": .string("New Markdown body, replacing the old one"),
        "tags": .array(of: .string(), description: "New tag list, replacing the old one"),
        "pinned": .boolean("Pin or unpin"),
    ], required: ["id"])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Note {
        let id = try parseID(input.id)
        guard input.title != nil || input.body != nil || input.tags != nil || input.pinned != nil else {
            throw ToolError.invalidInput("Nothing to change: pass title, body, tags or pinned.")
        }
        return try await service.update(id: id, title: input.title, body: input.body, tags: input.tags, pinned: input.pinned)
    }
}

public struct NoteAppendTool: Tool {
    public struct Input: Codable, Sendable {
        public var id: String
        public var text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }
    public static let name = "note.append"
    public static let summary = "Add text on a new line at the end of a note."
    public static let tier = PermissionTier.write
    public static let inputSchema = Schema.object(["id": idSchema, "text": .string("Markdown to add")], required: ["id", "text"])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Note {
        let id = try parseID(input.id)
        guard !input.text.isEmpty else { throw ToolError.invalidInput("text must not be empty.") }
        return try await service.append(id: id, text: input.text)
    }
}

public struct NoteDeleteTool: Tool {
    public struct Input: Codable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }
    public static let name = "note.delete"
    public static let summary = "Delete a note. It is kept as a tombstone and can be brought back with note.restore."
    public static let tier = PermissionTier.write
    public static let inputSchema = Schema.object(["id": idSchema], required: ["id"])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Ack {
        let note = try await service.delete(id: try parseID(input.id))
        return Ack(message: "Deleted \"\(note.displayTitle)\"")
    }
}

public struct NoteRestoreTool: Tool {
    public struct Input: Codable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }
    public static let name = "note.restore"
    public static let summary = "Bring back a note deleted with note.delete."
    public static let tier = PermissionTier.write
    public static let inputSchema = Schema.object(["id": idSchema], required: ["id"])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Note {
        try await service.restore(id: try parseID(input.id))
    }
}

public struct NoteTagsTool: Tool {
    public struct Output: Codable, Sendable, Equatable { public var tags: [String] }
    public static let name = "note.tags"
    public static let summary = "List every tag used by notes, sorted."
    public static let tier = PermissionTier.read
    public static let inputSchema = Schema.empty
    let service: NoteService

    public func run(_ input: Empty, context: ToolContext) async throws -> Output {
        Output(tags: await service.allTags())
    }
}

public struct NoteSyncTool: Tool {
    public struct Input: Decodable, Sendable {
        public var records: [JSONValue]
        public var since: Date?
    }
    public struct Output: Codable, Sendable, Equatable {
        public var records: [Note]
        public var serverTime: Date
        public var skipped: Int
    }
    public static let name = "note.sync"
    public static let summary = "Merge notes from the phone (newest updatedAt wins, deletes are tombstones) and return every note changed after since."
    public static let tier = PermissionTier.write
    public static let inputSchema = Schema.object([
        "records": .array(
            of: .object([
                "id": .string("Note UUID", format: "uuid"),
                "title": .string("Title; may be empty"),
                "body": .string("Markdown text"),
                "tags": .array(of: .string(), description: "Tags"),
                "pinned": .boolean("Pinned to the top"),
                "createdAt": .string("ISO-8601 time", format: "date-time"),
                "updatedAt": .string("ISO-8601 time of the last edit", format: "date-time"),
                "deletedAt": .string("ISO-8601 time the note was deleted; omit if live", format: "date-time"),
            ], required: ["id", "title", "body", "tags", "pinned", "createdAt", "updatedAt"]),
            description: "The sender's notes to merge; may be empty"),
        "since": .string("ISO-8601 time; only notes updated after it are returned (all when omitted)", format: "date-time"),
    ], required: ["records"])
    let service: NoteService

    public func run(_ input: Input, context: ToolContext) async throws -> Output {
        var notes: [Note] = []
        var skipped = 0
        for raw in input.records {
            if let n = try? raw.decode(Note.self) { notes.append(n) } else { skipped += 1 }
        }
        let r = try await service.sync(records: notes, since: input.since)
        return Output(records: r.records, serverTime: r.serverTime, skipped: skipped)
    }
}
