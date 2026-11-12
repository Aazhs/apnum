import ApnumCore
import Foundation
import Synchronization
import Testing
@testable import ApnumNotes

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A clock the test can move.
private final class Clock: Sendable {
    private let value = Mutex(t0)
    func advance(_ s: TimeInterval = 60) { value.withLock { $0 = $0.addingTimeInterval(s) } }
    var now: Date { value.withLock { $0 } }
}

private func makeService(_ paths: AppPaths = .temporary(), clock: Clock = Clock(), feed: ChangeFeed = ChangeFeed()) -> (NoteService, Clock, AppPaths) {
    (NoteService(paths: paths, changes: feed, now: { clock.now }), clock, paths)
}

@Suite struct FrontMatterTests {
    @Test func nastyValuesRoundTrip() throws {
        let titles = ["Shopping: milk, eggs", "He said \"hi\" & 'bye'", "日本語 🎉 ünïcödé", "- dash", "# not a comment", "  padded  ",
                      "", "line\nbreak\ttab", "back\\slash", "---", "true", "[brackets]"]
        let tags = ["home", "a, b", "two words", "quote\"d", "emoji🎉", "#hash", "x]y", " lead"]
        let bodies = ["", "plain", "---\nnot header\n---\n", "trailing newline\n", "\n\nleading blanks", "crlf\r\nline\r\n", "title: fake\n"]
        for title in titles {
            for body in bodies {
                let note = Note(title: title, body: body, tags: tags, pinned: true, createdAt: t0, updatedAt: t0.addingTimeInterval(5.5),
                                deletedAt: t0.addingTimeInterval(100))
                let parsed = try NoteFile.parse(NoteFile.serialize(note))
                #expect(parsed == note, "title: \(title.debugDescription) body: \(body.debugDescription)")
            }
        }
    }

    @Test func formatLooksHumanReadable() {
        let note = Note(title: "Shopping", body: "- milk\n", tags: ["home", "errands"], createdAt: t0)
        let text = NoteFile.serialize(note)
        #expect(text.contains("title: Shopping\n"))
        #expect(text.contains("tags: [home, errands]\n"))
        #expect(text.contains("pinned: false\n"))
        #expect(!text.contains("deleted:"))
        #expect(text.hasSuffix("---\n- milk\n"))
    }

    @Test func parsesHandWrittenFileWithComment() throws {
        let text = "---\nid: 6F1C2B9E-0000-4000-8000-000000000000\ntitle: \"Hi\" # note\ncreated: 2026-11-12T10:00:00Z\nupdated: 2026-11-12T10:05:00Z\n---\nbody"
        let n = try NoteFile.parse(text)
        #expect(n.title == "Hi")
        #expect(n.body == "body")
        #expect(n.tags == [])
    }

    @Test func rejectsBadFiles() {
        for text in ["", "no header", "---\nid: nope\ncreated: 2026-11-12T10:00:00Z\n---\n", "---\nid: 6F1C2B9E-0000-4000-8000-000000000000\n",
                     "---\nid: 6F1C2B9E-0000-4000-8000-000000000000\ntitle: \"open\ncreated: 2026-11-12T10:00:00Z\n---\n"] {
            #expect(throws: (any Error).self) { try NoteFile.parse(text) }
        }
    }
}

@Suite struct NoteModelTests {
    @Test func displayTitleAndPreview() {
        #expect(Note(title: "  Mine ", body: "x", createdAt: t0).displayTitle == "Mine")
        #expect(Note(body: "\n\n## Heading here\nmore", createdAt: t0).displayTitle == "Heading here")
        #expect(Note(body: "###\n  \n- item", createdAt: t0).displayTitle == "- item")
        #expect(Note(createdAt: t0).displayTitle == "Untitled")
        #expect(Note(body: "#tag-like line", createdAt: t0).displayTitle == "#tag-like line")

        let n = Note(body: "# Title\n\nfirst   line\nsecond\n", createdAt: t0)
        #expect(n.preview == "Title first line second")
        let long = Note(body: String(repeating: "word ", count: 100), createdAt: t0)
        #expect(long.preview.count == 121)
        #expect(long.preview.hasSuffix("…"))
        #expect(Note(createdAt: t0).preview == "")
    }
}

@Suite struct NoteServiceTests {
    @Test func createWritesFileAndPersists() async throws {
        let (service, _, paths) = makeService()
        let n = try await service.create(title: "A: b", body: "hello", tags: ["x", "x", " y "], pinned: true)
        #expect(n.tags == ["x", "y"])
        let file = paths.root.appendingPathComponent("notes/\(n.id.uuidString).md")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let (again, _, _) = makeService(paths)
        try await again.load()
        #expect(await again.note(id: n.id) == n)
        #expect(await again.loadErrors().isEmpty)
    }

    @Test func mutationsPublishAndBumpUpdatedAt() async throws {
        let feed = ChangeFeed()
        let stream = feed.subscribe()
        let (service, clock, _) = makeService(feed: feed)
        let n = try await service.create(title: "T")
        clock.advance()
        let u = try await service.update(id: n.id, body: "b")
        #expect(u.updatedAt == t0.addingTimeInterval(60))
        #expect(u.createdAt == t0)
        #expect(u.title == "T")
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == .notes)
        #expect(await it.next() == .notes)
    }

    @Test func loadSkipsCorruptFilesAndReportsThem() async throws {
        let (service, _, paths) = makeService()
        let good = try await service.create(title: "ok")
        try "garbage".write(to: paths.directory("notes").appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x00]).write(to: paths.directory("notes").appendingPathComponent("binary.md"))
        try "ignored".write(to: paths.directory("notes").appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let (fresh, _, _) = makeService(paths)
        try await fresh.load()
        #expect(await fresh.notes().map(\.id) == [good.id])
        let errors = await fresh.loadErrors()
        #expect(errors.count == 2)
        #expect(errors.contains { $0.hasPrefix("bad.md") })
    }

    @Test func searchIgnoresCaseAndDiacriticsAndMatchesTags() async throws {
        let (service, _, _) = makeService()
        let a = try await service.create(title: "Café plans", body: "meet", tags: ["Travel"])
        let b = try await service.create(title: "Other", body: "Résumé draft", tags: ["work", "two words"])
        _ = try await service.create(title: "Nothing")
        #expect(await service.notes(query: "CAFE").map(\.id) == [a.id])
        #expect(await service.notes(query: "resume").map(\.id) == [b.id])
        #expect(await service.notes(query: "travel").map(\.id) == [a.id])
        #expect(await service.notes(query: "draft other").map(\.id) == [b.id])
        #expect(await service.notes(query: "zzz").isEmpty)
        #expect(await service.notes(tag: "WORK").map(\.id) == [b.id])
        #expect(await service.notes(query: "plans", tag: "work").isEmpty)
        #expect(await service.allTags() == ["Travel", "two words", "work"])
    }

    @Test func sortsPinnedFirstThenNewest() async throws {
        let (service, clock, _) = makeService()
        let old = try await service.create(title: "old")
        clock.advance()
        let mid = try await service.create(title: "mid")
        clock.advance()
        let pinned = try await service.create(title: "pinned", pinned: true)
        clock.advance()
        let new = try await service.create(title: "new")
        #expect(await service.notes().map(\.id) == [pinned.id, new.id, mid.id, old.id])
        clock.advance()
        _ = try await service.update(id: old.id, body: "touched")
        #expect(await service.notes().map(\.id) == [pinned.id, old.id, new.id, mid.id])
    }

    @Test func appendAddsOnNewLine() async throws {
        let (service, _, _) = makeService()
        let n = try await service.create(title: "L")
        #expect(try await service.append(id: n.id, text: "- one").body == "- one")
        #expect(try await service.append(id: n.id, text: "- two").body == "- one\n- two")
        _ = try await service.update(id: n.id, body: "ends\n")
        #expect(try await service.append(id: n.id, text: "next").body == "ends\nnext")
        await #expect(throws: ToolError.self) { _ = try await service.append(id: UUID(), text: "x") }
    }

    @Test func tombstoneRestoreAndPurge() async throws {
        let (service, clock, paths) = makeService()
        let n = try await service.create(title: "bye", tags: ["t"])
        clock.advance()
        let d = try await service.delete(id: n.id)
        #expect(d.deletedAt == clock.now)
        let file = paths.root.appendingPathComponent("notes/\(n.id.uuidString).md")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await service.notes().isEmpty)
        #expect(await service.notes(includeDeleted: true).count == 1)
        #expect(await service.allTags().isEmpty)
        await #expect(throws: ToolError.self) { _ = try await service.update(id: n.id, title: "x") }

        // Tombstone survives a reload.
        let (fresh, _, _) = makeService(paths)
        try await fresh.load()
        #expect(await fresh.note(id: n.id)?.deletedAt == clock.now)

        clock.advance()
        let r = try await service.restore(id: n.id)
        #expect(r.deletedAt == nil)
        #expect(await service.notes().count == 1)
        await #expect(throws: ToolError.self) { _ = try await service.restore(id: n.id) }

        _ = try await service.delete(id: n.id)
        #expect(try await service.purgeDeleted(olderThan: t0) == 0)
        #expect(try await service.purgeDeleted(olderThan: clock.now.addingTimeInterval(1)) == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await service.note(id: n.id) == nil)
    }
}

@Suite struct NoteToolTests {
    func registry() -> (ToolRegistry, NoteService) {
        let (service, _, _) = makeService()
        return (ToolRegistry(tools: service.makeTools()), service)
    }

    @Test func toolNamesAndTiers() {
        let (reg, _) = registry()
        #expect(reg.descriptors.map(\.name) == ["note.append", "note.create", "note.delete", "note.get", "note.list", "note.restore", "note.tags", "note.update"])
        #expect(reg.descriptor(named: "note.list")?.tier == .read)
        #expect(reg.descriptor(named: "note.tags")?.tier == .read)
        #expect(reg.descriptor(named: "note.get")?.tier == .read)
        #expect(reg.descriptor(named: "note.delete")?.tier == .write)
    }

    @Test func roundTripThroughRegistry() async throws {
        let (reg, _) = registry()
        let agent = Caller.agent("test")
        let created = try await reg.callJSON("note.create", input: ["title": "Shopping", "body": "- milk", "tags": ["home"]], caller: agent)
        guard case .string(let id)? = created["id"] else { Issue.record("no id"); return }

        _ = try await reg.callJSON("note.append", input: ["id": .string(id), "text": "- eggs"], caller: agent)
        let got = try await reg.callJSON("note.get", input: ["id": .string(id)], caller: agent)
        #expect(got["body"] == "- milk\n- eggs")

        let list = try await reg.callJSON("note.list", input: ["query": "shop"], caller: agent)
        #expect(list["total"] == 1)
        guard case .array(let items)? = list["notes"], let first = items.first else { Issue.record("no notes"); return }
        #expect(first["title"] == "Shopping")
        #expect(first["preview"] == "- milk - eggs")
        #expect(first["body"] == nil)

        _ = try await reg.callJSON("note.update", input: ["id": .string(id), "pinned": true, "tags": ["home", "errands"]], caller: agent)
        #expect(try await reg.callJSON("note.tags", caller: agent) == ["tags": ["errands", "home"]])

        _ = try await reg.callJSON("note.delete", input: ["id": .string(id)], caller: agent)
        #expect(try await reg.callJSON("note.list", caller: agent)["total"] == 0)
        await #expect(throws: ToolError.self) { _ = try await reg.callJSON("note.get", input: ["id": .string(id)], caller: agent) }
        _ = try await reg.callJSON("note.restore", input: ["id": .string(id)], caller: agent)
        #expect(try await reg.callJSON("note.list", caller: agent)["total"] == 1)
    }

    @Test func invalidInputsAreReported() async throws {
        let (reg, _) = registry()
        await #expect(throws: ToolError.self) { _ = try await reg.callJSON("note.get", input: ["id": "not-a-uuid"], caller: .ui) }
        do {
            _ = try await reg.callJSON("note.get", input: ["id": "not-a-uuid"], caller: .ui)
            Issue.record("expected failure")
        } catch let e as ToolError {
            guard case .invalidInput(let m) = e else { Issue.record("wrong error \(e)"); return }
            #expect(m.contains("note.list"))
        }
        let missing = UUID().uuidString
        await #expect(throws: ToolError.self) { _ = try await reg.callJSON("note.delete", input: ["id": .string(missing)], caller: .ui) }
        do { _ = try await reg.callJSON("note.update", input: ["id": .string(missing), "title": "x"], caller: .ui) } catch let e as ToolError {
            guard case .notFound = e else { Issue.record("wrong error \(e)"); return }
        }
        await #expect(throws: ToolError.self) { _ = try await reg.callJSON("note.create", input: [:], caller: .ui) }
        await #expect(throws: ToolError.self) { _ = try await reg.callJSON("note.update", input: ["id": .string(missing)], caller: .ui) }
        await #expect(throws: ToolError.self) { _ = try await reg.callJSON("note.list", input: ["limit": 0], caller: .ui) }
    }

    @Test func typedCallWorksForUI() async throws {
        let (reg, _) = registry()
        let n = try await reg.call(NoteCreateTool.self, .init(title: "T"))
        let out = try await reg.call(NoteListTool.self, .init(limit: 5))
        #expect(out.notes.map(\.id) == [n.id])
    }
}
