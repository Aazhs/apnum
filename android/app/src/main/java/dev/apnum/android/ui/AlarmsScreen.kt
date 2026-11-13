package dev.apnum.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.apnum.android.alarm.AlarmLogic
import dev.apnum.android.alarm.AlarmRepository
import dev.apnum.android.sync.AlarmRecord
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

private sealed interface Editing {
    data object New : Editing
    data class Existing(val id: String) : Editing
}

@Composable
fun AlarmsScreen(repo: AlarmRepository, syncStatus: String, fullScreenOk: Boolean) {
    val alarms by repo.store.live.collectAsState()
    var editing by remember { mutableStateOf<Editing?>(null) }
    val sorted = alarms.sortedWith(compareBy({ it.hour }, { it.minute }))

    LazyColumn(
        Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Alarms", style = MaterialTheme.typography.displaySmall)
                    Text(syncStatus, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                FilledTonalButton(onClick = { editing = Editing.New }) { Text("Add") }
            }
        }
        if (!fullScreenOk) item {
            Section("Full-screen alarm is off") {
                Text("Allow it on the Phone tab so a ringing alarm can light up a locked screen.", style = MaterialTheme.typography.bodyMedium)
            }
        }
        items(sorted, key = { it.id }) { a ->
            Section(AlarmLogic.repeatSummary(a)) {
                Row(Modifier.fillMaxWidth().clickable { editing = Editing.Existing(a.id) }, verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("%02d:%02d".format(a.hour, a.minute), style = MaterialTheme.typography.displayMedium,
                            color = if (a.isEnabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                        if (a.label.isNotBlank()) Text(a.label, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                    Switch(checked = a.isEnabled, onCheckedChange = { repo.setEnabled(a.id, it) })
                }
            }
        }
        if (sorted.isEmpty()) item {
            Text("No alarms yet. They work without your Mac, and sync with it when it is connected.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }

    editing?.let { e ->
        val existing = (e as? Editing.Existing)?.let { repo.get(it.id) }
        AlarmSheet(existing, onDismiss = { editing = null },
            onSave = { h, m, label, days, snooze ->
                if (existing == null) repo.create(h, m, label, days, snooze) else repo.update(existing.id, h, m, label, days, snooze)
                editing = null
            },
            onDelete = existing?.let { a -> { repo.delete(a.id); editing = null } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AlarmSheet(
    existing: AlarmRecord?, onDismiss: () -> Unit,
    onSave: (Int, Int, String, Set<DayOfWeek>, Int) -> Unit, onDelete: (() -> Unit)?,
) {
    val time = rememberTimePickerState(existing?.hour ?: 7, existing?.minute ?: 0, is24Hour = true)
    var label by remember { mutableStateOf(existing?.label.orEmpty()) }
    var days by remember { mutableStateOf(existing?.days ?: emptySet()) }
    var snooze by remember { mutableStateOf(existing?.snoozeMinutes ?: 9) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            TimePicker(time)
            OutlinedTextField(value = label, onValueChange = { label = it }, label = { Text("Label") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                DayOfWeek.entries.forEach { d ->
                    FilterChip(
                        selected = d in days, onClick = { days = if (d in days) days - d else days + d },
                        label = { Text(d.getDisplayName(TextStyle.NARROW, Locale.getDefault()), maxLines = 1) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Snooze", Modifier.padding(end = 4.dp))
                listOf(5, 9, 10, 15).forEach { m -> FilterChip(selected = snooze == m, onClick = { snooze = m }, label = { Text("$m min") }) }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (onDelete != null) TextButton(onClick = onDelete) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                Button(onClick = { onSave(time.hour, time.minute, label, days, snooze) }, modifier = Modifier.weight(1f)) { Text("Save") }
            }
        }
    }
}
