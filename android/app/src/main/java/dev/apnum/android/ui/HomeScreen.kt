package dev.apnum.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.apnum.android.link.ConnectionState
import dev.apnum.android.link.PairedMac
import dev.apnum.android.link.str
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

@Composable
fun HomeScreen(mac: PairedMac?, state: ConnectionState, remote: MacRemote, demo: Boolean) {
    val timers by remote.timers.collectAsState()
    val tools = remote.tools.collectAsState().value // read here so the screen recomposes when the Mac's tool list arrives
    val connected = demo || state == ConnectionState.Connected

    LazyColumn(
        Modifier.fillMaxWidth(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 20.dp, vertical = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { Header(if (demo) "Demo Mac" else mac?.name ?: "Your Mac", connected, state) }
        if (remote.hasRemote || demo) item { RemoteSection(remote, tools) }
        if (remote.has("timer.start") || demo) item { TimersSection(remote, timers) }
        if (!connected) item {
            Text(
                "The Mac controls appear here once the phone is connected. Make sure both are on the same Wi-Fi.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Header(name: String, connected: Boolean, state: ConnectionState) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(name, style = MaterialTheme.typography.displaySmall)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(10.dp).background(if (connected) MaterialTheme.colorScheme.primary else Color(0x55FFFFFF), CircleShape))
            Text(
                when {
                    connected -> "Connected"
                    state == ConnectionState.Connecting -> "Connecting"
                    else -> "Looking for your Mac"
                },
                style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun RemoteSection(remote: MacRemote, @Suppress("UNUSED_PARAMETER") tools: List<dev.apnum.android.link.ToolDescriptor>) {
    val ctx = LocalContext.current
    val volume by remote.volume.collectAsState()
    val muted by remote.muted.collectAsState()
    var dragging by remember { mutableStateOf<Float?>(null) }

    Section("Mac remote") {
        if (remote.has("mac.volume.set") || remote.demo.value) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("${(dragging ?: volume?.toFloat() ?: 0f).toInt()}", style = MaterialTheme.typography.displaySmall, modifier = Modifier.padding(end = 4.dp))
                Slider(
                    value = dragging ?: volume?.toFloat() ?: 0f, onValueChange = { dragging = it }, valueRange = 0f..100f,
                    onValueChangeFinished = {
                        dragging?.let { v ->
                            remote.volume.value = v.toInt()
                            remote.act("mac.volume.set", buildJsonObject { put("volume", v.toInt()) }) { remote.readVolume(it) }
                        }
                        dragging = null
                    },
                    modifier = Modifier.weight(1f),
                )
                FilledTonalButton(onClick = {
                    remote.act("mac.volume.set", buildJsonObject { put("muted", muted != true) }) { remote.readVolume(it) }
                }) { Text(if (muted == true) "Unmute" else "Mute") }
            }
        }
        if (remote.has("mac.media.control") || remote.demo.value) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                listOf("Previous" to "previous", "Play" to "play_pause", "Next" to "next").forEach { (label, action) ->
                    FilledTonalButton(onClick = { remote.act("mac.media.control", buildJsonObject { put("action", action) }) }, modifier = Modifier.weight(1f)) {
                        Text(label, maxLines = 1)
                    }
                }
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (remote.has("mac.lock") || remote.demo.value) OutlinedButton(onClick = { remote.act("mac.lock") }) { Text("Lock") }
            if (remote.has("mac.display.sleep") || remote.demo.value) OutlinedButton(onClick = { remote.act("mac.display.sleep") }) { Text("Sleep display") }
            if (remote.has("mac.clipboard.set") || remote.demo.value) OutlinedButton(onClick = {
                val cm = ctx.getSystemService(ClipboardManager::class.java)
                val text = runCatching { cm.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString() }.getOrNull()
                if (text.isNullOrEmpty()) remote.say("Your phone clipboard is empty.")
                else remote.act("mac.clipboard.set", buildJsonObject { put("text", text) }) { remote.say("Sent to your Mac clipboard.") }
            }) { Text("Send clipboard to Mac") }
            if (remote.has("mac.clipboard.get") || remote.demo.value) OutlinedButton(onClick = {
                remote.act("mac.clipboard.get") { out ->
                    val text = (out as? JsonObject)?.str("text")
                    if (text.isNullOrEmpty()) remote.say("The Mac clipboard has no text.")
                    else {
                        ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("apnum", text))
                        remote.say("Copied from your Mac.")
                    }
                }
            }) { Text("Get Mac clipboard") }
        }
    }
}

@Composable
private fun TimersSection(remote: MacRemote, timers: List<TimerItem>) {
    val now by produceState(System.currentTimeMillis(), timers) {
        while (timers.any { it.running }) {
            value = System.currentTimeMillis()
            delay(1000)
        }
        value = System.currentTimeMillis()
    }
    Section("Timers") {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(1, 5, 10, 25).forEach { m ->
                AssistChip(onClick = { remote.act("timer.start", buildJsonObject { put("minutes", m) }) { remote.refreshTimers() } }, label = { Text("$m min") })
            }
        }
        timers.forEach { t ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(clock(t.remainingAt(now)), style = MaterialTheme.typography.displaySmall)
                    Text(
                        listOf(t.label.ifBlank { "Timer" }, t.state).joinToString(" - "),
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                when (t.state) {
                    "running" -> TextButton(onClick = { remote.act("timer.pause", idInput(t.id)) { remote.refreshTimers() } }) { Text("Pause") }
                    "paused" -> TextButton(onClick = { remote.act("timer.resume", idInput(t.id)) { remote.refreshTimers() } }) { Text("Resume") }
                    "ringing" -> TextButton(onClick = { remote.act("timer.stop", idInput(t.id)) { remote.refreshTimers() } }) { Text("Stop") }
                }
                TextButton(onClick = { remote.act("timer.cancel", idInput(t.id)) { remote.refreshTimers() } }) { Text("Cancel") }
            }
        }
        if (timers.isEmpty()) Text("No timers running.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun idInput(id: String) = buildJsonObject { put("id", id) }

/** 214 -> "3:34", 3725 -> "1:02:05". */
fun clock(totalSeconds: Long): String {
    val h = totalSeconds / 3600
    val m = totalSeconds % 3600 / 60
    val s = totalSeconds % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
