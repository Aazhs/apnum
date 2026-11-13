package dev.apnum.android.notes

import dev.apnum.android.sync.NoteRecord
import dev.apnum.android.sync.SyncStore
import dev.apnum.android.sync.Wire
import java.text.Normalizer
import java.time.Instant

class NoteRepository(val store: SyncStore<NoteRecord>, private val clock: () -> Instant = { Instant.now() }) {
    fun get(id: String): NoteRecord? = store.get(id.uppercase())?.takeIf { !it.isDeleted }

    /** A new empty note; it is only kept once it has text (see [save]). */
    fun newId(): String = Wire.newId()

    /** Saves the editor's state. An untouched new note leaves nothing behind. Returns false when nothing was stored. */
    fun save(id: String, title: String, body: String, tags: List<String>, pinned: Boolean): Boolean {
        val old = store.get(id.uppercase())
        if (old?.isDeleted == true) return false // deleted notes stay deleted, even if the editor saves once more
        val clean = tags.map { it.trim().trimStart('#') }.filter { it.isNotEmpty() }.distinct()
        if (old == null) {
            if (title.isBlank() && body.isBlank() && clean.isEmpty()) return false
            val now = clock()
            store.put(NoteRecord(id.uppercase(), title.trim(), body, clean, pinned, now, now))
            return true
        }
        if (old.title == title.trim() && old.body == body && old.tags == clean && old.pinned == pinned && !old.isDeleted) return true
        store.put(old.copy(title = title.trim(), body = body, tags = clean, pinned = pinned, updatedAt = clock(), deletedAt = null))
        return true
    }

    fun delete(id: String) {
        val old = get(id) ?: return
        val now = clock()
        store.put(old.copy(updatedAt = now, deletedAt = now))
    }

    companion object {
        /** Pinned first, then newest; [query] words must all appear in the title, body or tags; [tag] filters. */
        fun filter(notes: List<NoteRecord>, query: String, tag: String?): List<NoteRecord> {
            val words = fold(query).split(' ').filter { it.isNotEmpty() }
            return notes.filter { n ->
                (tag == null || n.tags.any { it.equals(tag, true) }) &&
                    words.all { w -> fold(n.title).contains(w) || fold(n.body).contains(w) || n.tags.any { fold(it).contains(w) } }
            }.sortedWith(compareByDescending<NoteRecord> { it.pinned }.thenByDescending { it.updatedAt })
        }

        fun allTags(notes: List<NoteRecord>): List<String> = notes.flatMap { it.tags }.distinctBy { it.lowercase() }.sortedBy { it.lowercase() }

        fun displayTitle(n: NoteRecord): String = n.title.ifBlank { n.body.lineSequence().firstOrNull { it.isNotBlank() }?.trimStart('#', ' ')?.take(60).orEmpty() }.ifBlank { "Untitled" }

        fun preview(n: NoteRecord): String =
            n.body.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.drop(if (n.title.isBlank()) 1 else 0).firstOrNull().orEmpty().take(120)

        private fun fold(s: String) = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()
    }
}
