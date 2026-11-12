import ApnumCore
import Foundation

/// Owns the notes on disk (`<root>/notes/<uuid>.md`) and in memory.
public actor NoteService {
    private let paths: AppPaths
    private let changes: ChangeFeed
    private let now: @Sendable () -> Date
    private var store: [UUID: Note] = [:]
    private var errors: [String] = []

    public init(paths: AppPaths, changes: ChangeFeed, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.changes = changes
        self.now = now
    }

    private var directory: URL { paths.directory("notes") }
    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).md", isDirectory: false) }

    // MARK: Loading

    /// Reads every `.md` file in notes/. Files that cannot be parsed are skipped; see `loadErrors()`.
    public func load() async throws {
        let dir = directory
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
        var loaded: [UUID: Note] = [:]
        var problems: [String] = []
        for url in files {
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else { throw NoteFile.ParseError("not valid UTF-8") }
                let note = try NoteFile.parse(text)
                loaded[note.id] = note
            } catch {
                problems.append("\(url.lastPathComponent): \(error)")
            }
        }
        store = loaded
        errors = problems.sorted()
        changes.publish(.notes)
    }

    /// Human-readable descriptions of files skipped by the last `load()`.
    public func loadErrors() -> [String] { errors }

    // MARK: Reading

    /// Notes matching the filters, pinned first, then most recently updated.
    /// `query` words must all appear in the title, body or tags (case and diacritics ignored).
    public func notes(query: String? = nil, tag: String? = nil, includeDeleted: Bool = false) -> [Note] {
        let terms = (query ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let wantedTag = tag?.trimmingCharacters(in: .whitespaces)
        return store.values.filter { note in
            if note.isDeleted && !includeDeleted { return false }
            if let wantedTag, !wantedTag.isEmpty, !note.tags.contains(where: { Self.fold($0) == Self.fold(wantedTag) }) { return false }
            if terms.isEmpty { return true }
            let haystack = Self.fold(([note.title, note.body] + note.tags).joined(separator: "\n"))
            return terms.allSatisfy { haystack.contains(Self.fold($0)) }
        }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func note(id: UUID) -> Note? { store[id] }

    /// Sorted, unique tags of notes that are not deleted.
    public func allTags() -> [String] {
        Array(Set(store.values.filter { !$0.isDeleted }.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Changing

    @discardableResult
    public func create(title: String = "", body: String = "", tags: [String] = [], pinned: Bool = false) async throws -> Note {
        let stamp = now()
        let note = Note(title: title, body: body, tags: Self.cleanTags(tags), pinned: pinned, createdAt: stamp)
        try save(note)
        return note
    }

    /// Changes the given fields; nil leaves a field as it is.
    @discardableResult
    public func update(id: UUID, title: String? = nil, body: String? = nil, tags: [String]? = nil, pinned: Bool? = nil) async throws -> Note {
        var note = try live(id)
        if let title { note.title = title }
        if let body { note.body = body }
        if let tags { note.tags = Self.cleanTags(tags) }
        if let pinned { note.pinned = pinned }
        note.updatedAt = now()
        try save(note)
        return note
    }

    /// Adds `text` on a new line at the end of the body.
    @discardableResult
    public func append(id: UUID, text: String) async throws -> Note {
        var note = try live(id)
        if note.body.isEmpty || note.body.hasSuffix("\n") { note.body += text } else { note.body += "\n" + text }
        note.updatedAt = now()
        try save(note)
        return note
    }

    /// Marks the note deleted. The file stays so the deletion can sync.
    @discardableResult
    public func delete(id: UUID) async throws -> Note {
        var note = try live(id)
        let stamp = now()
        note.deletedAt = stamp
        note.updatedAt = stamp
        try save(note)
        return note
    }

    @discardableResult
    public func restore(id: UUID) async throws -> Note {
        guard var note = store[id], note.isDeleted else {
            throw ToolError.notFound("No deleted note with id \(id.uuidString)")
        }
        note.deletedAt = nil
        note.updatedAt = now()
        try save(note)
        return note
    }

    /// Removes the files of notes deleted before `date`. Returns how many were removed.
    @discardableResult
    public func purgeDeleted(olderThan date: Date) async throws -> Int {
        let doomed = store.values.filter { ($0.deletedAt ?? .distantFuture) < date }
        for note in doomed {
            try? FileManager.default.removeItem(at: fileURL(note.id))
            store[note.id] = nil
        }
        if !doomed.isEmpty { changes.publish(.notes) }
        return doomed.count
    }

    // MARK: Helpers

    private func live(_ id: UUID) throws -> Note {
        guard let note = store[id], !note.isDeleted else {
            throw ToolError.notFound("No note with id \(id.uuidString). Use note.list to find note ids.")
        }
        return note
    }

    private func save(_ note: Note) throws {
        let data = Data(NoteFile.serialize(note).utf8)
        try data.write(to: fileURL(note.id), options: .atomic)
        store[note.id] = note
        changes.publish(.notes)
    }

    private static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
