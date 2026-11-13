package dev.apnum.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import dev.apnum.android.notes.NoteRepository
import kotlinx.coroutines.delay

@Composable
fun NotesScreen(repo: NoteRepository, syncStatus: String, openId: String? = null) {
    var editingId by rememberSaveable { mutableStateOf(openId) }
    val id = editingId
    if (id != null) {
        NoteEditor(repo, id, onClose = { editingId = null })
    } else {
        NoteList(repo, syncStatus, onOpen = { editingId = it }, onNew = { editingId = repo.newId() })
    }
}

@Composable
private fun NoteList(repo: NoteRepository, syncStatus: String, onOpen: (String) -> Unit, onNew: () -> Unit) {
    val notes by repo.store.live.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var tag by rememberSaveable { mutableStateOf<String?>(null) }
    val tags = NoteRepository.allTags(notes)
    val shown = NoteRepository.filter(notes, query, tag)

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 28.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Notes", style = MaterialTheme.typography.displaySmall)
                    Text(syncStatus, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                FilledTonalButton(onClick = onNew) { Text("New") }
            }
        }
        item {
            OutlinedTextField(value = query, onValueChange = { query = it }, label = { Text("Search") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        }
        if (tags.isNotEmpty()) item {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                tags.forEach { t -> FilterChip(selected = tag.equals(t, true), onClick = { tag = if (tag.equals(t, true)) null else t }, label = { Text(t, maxLines = 1) }) }
            }
        }
        items(shown, key = { it.id }) { n ->
            Section(if (n.pinned) "Pinned" else n.tags.joinToString(" ") { "#$it" }.ifBlank { "Note" }) {
                Column(Modifier.fillMaxWidth().clickable { onOpen(n.id) }, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(NoteRepository.displayTitle(n), style = MaterialTheme.typography.titleLarge, maxLines = 1)
                    val p = NoteRepository.preview(n)
                    if (p.isNotBlank()) Text(p, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                }
            }
        }
        if (shown.isEmpty()) item {
            Text(if (notes.isEmpty()) "No notes yet. They work without your Mac, and sync with it when it is connected." else "No notes match.",
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun NoteEditor(repo: NoteRepository, id: String, onClose: () -> Unit) {
    val existing = remember(id) { repo.get(id) }
    var title by rememberSaveable(id) { mutableStateOf(existing?.title.orEmpty()) }
    var body by rememberSaveable(id) { mutableStateOf(existing?.body.orEmpty()) }
    var tags by rememberSaveable(id) { mutableStateOf(existing?.tags?.joinToString(", ").orEmpty()) }
    var pinned by rememberSaveable(id) { mutableStateOf(existing?.pinned ?: false) }
    var confirmDelete by remember { mutableStateOf(false) }

    fun tagList() = tags.split(',', ' ').map { it.trim() }.filter { it.isNotEmpty() }
    fun save() = repo.save(id, title, body, tagList(), pinned)

    // Autosave shortly after the last keystroke, and once more when leaving.
    LaunchedEffect(title, body, tags, pinned) { delay(600); save() }
    val latest by rememberUpdatedState(::save)
    DisposableEffect(id) { onDispose { latest() } }
    BackHandler { save(); onClose() }

    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = { save(); onClose() }) { Text("Done") }
            Row(Modifier.weight(1f)) {}
            TextButton(onClick = { pinned = !pinned }) { Text(if (pinned) "Unpin" else "Pin") }
            TextButton(onClick = { confirmDelete = true }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
        }
        val plain = TextFieldDefaults.colors(
            focusedContainerColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedContainerColor = androidx.compose.ui.graphics.Color.Transparent,
            focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
        )
        androidx.compose.material3.TextField(
            value = title, onValueChange = { title = it }, placeholder = { Text("Title", style = MaterialTheme.typography.headlineMedium) },
            textStyle = MaterialTheme.typography.headlineMedium, singleLine = true, colors = plain,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences), modifier = Modifier.fillMaxWidth(),
        )
        androidx.compose.material3.TextField(
            value = tags, onValueChange = { tags = it }, placeholder = { Text("Tags, separated by commas") },
            singleLine = true, colors = plain, modifier = Modifier.fillMaxWidth(),
        )
        androidx.compose.material3.TextField(
            value = body, onValueChange = { body = it }, placeholder = { Text("Write in Markdown") },
            colors = plain, modifier = Modifier.fillMaxWidth().weight(1f),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
        )
    }

    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete this note?") },
        text = { Text("It is removed here and on your Mac.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; repo.delete(id); onClose() }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}
