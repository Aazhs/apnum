import ApnumCore
import ApnumNotes
import Observation
import SwiftUI

/// Notes: a searchable list that switches to an editor in place.
struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var tagFilter: String?
    @State private var draft: NoteDraft?

    var body: some View {
        if let draft {
            NoteEditor(draft: draft) { self.draft = nil }
        } else {
            list
        }
    }

    private var visibleNotes: [Note] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.noteList
            .filter { !$0.isDeleted }
            .filter { note in
                if let tagFilter, !note.tags.contains(tagFilter) { return false }
                if q.isEmpty { return true }
                return note.title.localizedStandardContains(q) || note.body.localizedStandardContains(q)
                    || note.tags.contains { $0.localizedStandardContains(q) }
            }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.updatedAt > b.updatedAt
            }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))

                if !model.noteTags.isEmpty {
                    Menu {
                        Button("All tags") { tagFilter = nil }
                        Divider()
                        ForEach(model.noteTags, id: \.self) { tag in
                            Button {
                                tagFilter = tag
                            } label: {
                                if tagFilter == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                            }
                        }
                    } label: {
                        Image(systemName: tagFilter == nil ? "tag" : "tag.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Filter by tag")
                }

                Button { draft = NoteDraft(note: nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New note")
                    .accessibilityLabel("New note")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            Divider()

            if model.noteList.filter({ !$0.isDeleted }).isEmpty {
                emptyState(
                    icon: "note.text", title: "No notes yet",
                    hint: "Jot something down. Notes are plain Markdown.", action: "New Note"
                ) {
                    draft = NoteDraft(note: nil)
                }
            } else if visibleNotes.isEmpty {
                emptyState(
                    icon: "magnifyingglass", title: "No matches",
                    hint: "Try a different search or clear the tag filter.", action: nil
                ) {}
            } else {
                List(visibleNotes) { note in
                    NoteRow(note: note)
                        .contentShape(Rectangle())
                        .onTapGesture { draft = NoteDraft(note: note) }
                        .contextMenu {
                            Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") {
                                Task {
                                    await model.run("note.update", ["id": .string(note.id.uuidString), "pinned": .bool(!note.pinned)])
                                }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.run("note.delete", ["id": .string(note.id.uuidString)]) }
                            }
                        }
                        .accessibilityAddTraits(.isButton)
                }
                .listStyle(.plain)
            }
        }
    }

    private func emptyState(
        icon: String, title: String, hint: String, action: String?, perform: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action, action: perform).buttonStyle(.borderedProminent).controlSize(.regular)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity).padding()
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                        .accessibilityLabel("Pinned")
                }
                Text(note.displayTitle).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !note.preview.isEmpty {
                Text(note.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.tags, id: \.self) { tag in
                        Text(tag).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Editing state for one note, with debounced autosave. Creates the note on the
/// first non-empty save and then keeps updating it by id.
@MainActor @Observable
private final class NoteDraft {
    enum SaveState { case idle, saving, saved }

    var title: String
    var body: String
    var tagsText: String
    var pinned: Bool
    private(set) var noteID: UUID?
    private(set) var state: SaveState = .idle

    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var dirty = false

    init(note: Note?) {
        noteID = note?.id
        title = note?.title ?? ""
        body = note?.body ?? ""
        tagsText = note?.tags.joined(separator: ", ") ?? ""
        pinned = note?.pinned ?? false
    }

    private var tags: [String] {
        tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
        }
        state = .saved
    }
}

private struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: NoteDraft
    let close: () -> Void
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await draft.flush(model); close() }
                } label: {
                    Label("Notes", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back to notes")

                Spacer()
                switch draft.state {
                case .idle: EmptyView()
                case .saving: Text("Saving…").font(.caption).foregroundStyle(.secondary)
                case .saved: Text("Saved").font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $draft.pinned) {
                    Image(systemName: draft.pinned ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Pin note")
                .accessibilityLabel("Pinned")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .onSubmit { bodyFocused = true }
                HStack(spacing: 4) {
                    Image(systemName: "tag").foregroundStyle(.secondary).font(.caption)
                    TextField("Tags, comma separated", text: $draft.tagsText)
                        .textFieldStyle(.plain).font(.callout)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            TextEditor(text: $draft.body)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($bodyFocused)
                .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .onChange(of: draft.title) { draft.changed(model) }
        .onChange(of: draft.body) { draft.changed(model) }
        .onChange(of: draft.tagsText) { draft.changed(model) }
        .onChange(of: draft.pinned) { draft.changed(model) }
        .onDisappear { Task { await draft.flush(model) } }
    }
}
