import ApnumCore
import ApnumNotes
import Observation
import SwiftUI

/// Notes: a list of notes beside an editor, in the spirit of Apple Notes.
struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var tagFilter: String?
    @State private var selection: UUID?
    @State private var draft: NoteDraft?

    private var liveNotes: [Note] { model.noteList.filter { !$0.isDeleted } }

    private var visibleNotes: [Note] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return liveNotes
            .filter { note in
                if let tagFilter, !note.tags.contains(tagFilter) { return false }
                if q.isEmpty { return true }
                return note.title.localizedStandardContains(q) || note.body.localizedStandardContains(q)
                    || note.tags.contains { $0.localizedStandardContains(q) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        content
            .navigationTitle("Notes")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Search notes")
            .toolbar { toolbar }
            .onAppear {
                if let id = model.focusNoteID {
                    open(id)
                    model.focusNoteID = nil
                } else {
                    openDefault()
                }
            }
            .onChange(of: liveNotes.count) { openDefault() }
            .onChange(of: model.focusNoteID) { _, id in
                guard let id else { return }
                query = ""
                tagFilter = nil
                open(id)
                model.focusNoteID = nil
            }
            .onChange(of: selection) { _, id in
                guard let id, id != draft?.noteID else { return }
                open(id)
            }
            .onDisappear {
                if let draft { Task { await draft.flush(model) } }
            }
    }

    @ViewBuilder
    private var content: some View {
        if liveNotes.isEmpty && draft == nil {
            ContentUnavailableView {
                Label("No notes", systemImage: "note.text")
            } description: {
                Text("Notes are Markdown files on this Mac. Your agents can read and write them too.")
            } actions: {
                Button("New note", action: newNote).buttonStyle(.pill(.accentColor))
            }
        } else {
            HSplitView {
                list
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                editorPane
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if visibleNotes.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            let pinned = visibleNotes.filter(\.pinned)
            let others = visibleNotes.filter { !$0.pinned }
            List(selection: $selection) {
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { row($0) }
                    }
                }
                if !others.isEmpty {
                    Section(pinned.isEmpty ? "" : "Notes") {
                        ForEach(others) { row($0) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ note: Note) -> some View {
        NoteRow(note: note)
            .tag(note.id)
            .contextMenu {
                Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") {
                    Task { await model.run("note.update", ["id": .string(note.id.uuidString), "pinned": .bool(!note.pinned)]) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { delete(note.id) }
            }
    }

    // MARK: Editor

    @ViewBuilder
    private var editorPane: some View {
        if let draft {
            NoteEditor(draft: draft)
                .id(draft.token)
        } else {
            Text("Select a note or create one")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subtitle: String {
        guard let draft else { return "" }
        switch draft.state {
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .idle:
            if let date = draft.updatedAt { return "Edited \(date.formatted(.dateTime.month().day().hour().minute()))" }
            return ""
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("All tags") { tagFilter = nil }
                if !model.noteTags.isEmpty { Divider() }
                ForEach(model.noteTags, id: \.self) { tag in
                    Button {
                        tagFilter = tag
                    } label: {
                        if tagFilter == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                    }
                }
            } label: {
                Label("Filter by tag", systemImage: tagFilter == nil ? "tag" : "tag.fill")
            }
            .help("Filter by tag")
        }
        ToolbarSpacer(.fixed)
        if let draft {
            ToolbarItem {
                Button {
                    draft.pinned.toggle()
                    draft.changed(model)
                    Task { await draft.flush(model) }
                } label: {
                    Label(draft.pinned ? "Unpin" : "Pin", systemImage: draft.pinned ? "pin.fill" : "pin")
                }
                .help(draft.pinned ? "Unpin note" : "Pin note")
            }
            ToolbarItem {
                Button {
                    if let id = draft.noteID {
                        delete(id)
                    } else {
                        self.draft = nil
                        selection = nil
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete note")
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Button(action: newNote) {
                Label("New note", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New note")
        }
    }

    // MARK: Actions

    private func open(_ id: UUID) {
        guard let note = model.noteList.first(where: { $0.id == id }) else { return }
        let old = draft
        draft = NoteDraft(note: note)
        selection = id
        if let old { Task { await old.flush(model) } }
    }

    private func openDefault() {
        guard draft == nil, let first = visibleNotes.first(where: \.pinned) ?? visibleNotes.first else { return }
        open(first.id)
    }

    private func newNote() {
        let old = draft
        draft = NoteDraft(note: nil)
        selection = nil
        if let old { Task { await old.flush(model) } }
    }

    private func delete(_ id: UUID) {
        let next = visibleNotes.first { $0.id != id }?.id
        if draft?.noteID == id {
            draft?.cancel()
            draft = nil
            selection = nil
        }
        Task {
            await model.run("note.delete", ["id": .string(id.uuidString)])
            if let next, draft == nil { open(next) }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    private var dateText: String {
        let cal = Calendar.current
        if cal.isDateInToday(note.updatedAt) { return note.updatedAt.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(note.updatedAt) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: note.updatedAt, to: .now).day, days < 7 {
            return note.updatedAt.formatted(.dateTime.weekday(.wide))
        }
        return note.updatedAt.formatted(date: .numeric, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(dateText).foregroundStyle(.primary.opacity(0.8))
                Text(note.preview.isEmpty ? "No additional text" : note.preview)
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.tags, id: \.self) { TagCapsule(tag: $0) }
                }
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct TagCapsule: View {
    let tag: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(tag)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.tint.opacity(0.14), in: Capsule())
    }
}

/// Editing state for one note, with debounced autosave. Creates the note on the
/// first non-empty save and then keeps updating it by id.
@MainActor @Observable
private final class NoteDraft {
    enum SaveState { case idle, saving, saved }

    let token = UUID()
    var title: String
    var body: String
    var tags: [String]
    var pinned: Bool
    private(set) var noteID: UUID?
    private(set) var updatedAt: Date?
    private(set) var state: SaveState = .idle

    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var dirty = false

    init(note: Note?) {
        noteID = note?.id
        updatedAt = note?.updatedAt
        title = note?.title ?? ""
        body = note?.body ?? ""
        tags = note?.tags ?? []
        pinned = note?.pinned ?? false
    }

    func changed(_ model: AppModel) {
        dirty = true
        state = .saving
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.save(model)
        }
    }

    /// Drops pending edits (the note is being deleted).
    func cancel() {
        debounce?.cancel()
        dirty = false
    }

    /// Saves pending edits now (used when leaving the editor).
    func flush(_ model: AppModel) async {
        debounce?.cancel()
        await save(model)
    }

    private func save(_ model: AppModel) async {
        guard dirty else { return }
        if saving { return }  // the running loop picks up `dirty`
        saving = true
        defer { saving = false }
        while dirty {
            dirty = false
            let empty = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if empty && noteID == nil { state = .idle; continue }
            var input: [String: JSONValue] = [
                "title": .string(title), "body": .string(body),
                "tags": .array(tags.map { .string($0) }), "pinned": .bool(pinned),
            ]
            if let noteID {
                input["id"] = .string(noteID.uuidString)
                _ = await model.run("note.update", .object(input))
            } else if let out = await model.run("note.create", .object(input)),
                case .string(let s)? = out["id"], let id = UUID(uuidString: s)
            {
                noteID = id
            }
            updatedAt = .now
        }
        state = .saved
    }
}

private struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: NoteDraft
    @State private var tagInput = ""
    @FocusState private var focus: Field?
    private enum Field { case title, tag, body }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .semibold))
                .focused($focus, equals: .title)
                .onSubmit { focus = .body }
                .padding(.horizontal, 5)

            metaLine
                .padding(.horizontal, 5)
                .padding(.top, 6)
                .padding(.bottom, 14)

            TextEditor(text: $draft.body)
                .font(.system(size: 15))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focus, equals: .body)
        }
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onChange(of: draft.title) { draft.changed(model) }
        .onChange(of: draft.body) { draft.changed(model) }
        .onChange(of: draft.tags) { draft.changed(model) }
        .onAppear { if draft.noteID == nil { focus = .title } }
        .onDisappear { Task { await draft.flush(model) } }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            if let date = draft.updatedAt {
                Text(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.tags, id: \.self) { tag in
                TagCapsule(tag: tag) { draft.tags.removeAll { $0 == tag } }
            }
            TextField("Add tag", text: $tagInput)
                .textFieldStyle(.plain)
                .focused($focus, equals: .tag)
                .frame(width: 80)
                .onSubmit { commitTag() }
                .onChange(of: tagInput) { _, new in
                    if new.contains(",") { commitTag() }
                }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func commitTag() {
        for piece in tagInput.split(separator: ",") {
            let tag = piece.trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty && !draft.tags.contains(tag) { draft.tags.append(tag) }
        }
        tagInput = ""
    }
}
