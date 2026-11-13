package dev.apnum.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import dev.apnum.android.AppGraph
import dev.apnum.android.BuildConfig
import dev.apnum.android.phone.ClipboardAccessibilityService
import dev.apnum.android.update.UpdateUi
import dev.apnum.android.link.PairedMac
import uniffi.apnum_link.fingerprint

private val licences = """
apnum is MIT licensed.

Built with:
- Kotlin, Jetpack Compose, AndroidX, kotlinx.coroutines, kotlinx.serialization (Apache 2.0)
- OkHttp and Okio (Apache 2.0)
- Java Native Access, JNA (Apache 2.0 or LGPL, used under Apache 2.0)
- Google Play services code scanner (Google Play services terms)
- apnum-link, the shared Rust link core, with snow, x25519-dalek, chacha20poly1305 and blake2 (MIT or Apache 2.0)
""".trimIndent()

@Composable
fun SettingsScreen(mac: PairedMac?, deviceName: String, graph: AppGraph, refresh: Int, onUnpair: () -> Unit) {
    val ctx = LocalContext.current
    var confirm by remember { mutableStateOf(false) }
    var showLicences by remember { mutableStateOf(false) }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Settings", style = MaterialTheme.typography.displaySmall)
        Section("Paired Mac") {
            if (mac == null) {
                Text("No Mac is paired.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Text(mac.name, style = MaterialTheme.typography.headlineMedium)
                Text("Key fingerprint", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(runCatching { fingerprint(mac.publicKey) }.getOrDefault("unavailable"), style = MaterialTheme.typography.titleMedium)
                Text("Last address ${mac.host}:${mac.port}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedButton(onClick = { confirm = true }) { Text("Unpair") }
            }
        }
        Section("This phone") {
            Text(deviceName, style = MaterialTheme.typography.titleMedium)
        }
        ClipboardSection(graph, ctx, refresh)
        UpdateSection(graph, ctx)
        Section("About") {
            Text("apnum for Android ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.titleMedium)
            TextButton(onClick = { showLicences = true }) { Text("Licences") }
        }
    }

    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text("Unpair from ${mac?.name}?") },
        text = { Text("The Mac forgets this phone and the phone forgets the Mac. You can pair again any time.") },
        confirmButton = { Button(onClick = { confirm = false; onUnpair() }) { Text("Unpair") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
    )
    if (showLicences) AlertDialog(
        onDismissRequest = { showLicences = false },
        title = { Text("Licences") },
        text = { Column(Modifier.verticalScroll(rememberScrollState())) { Text(licences, style = MaterialTheme.typography.bodyMedium) } },
        confirmButton = { TextButton(onClick = { showLicences = false }) { Text("Close") } },
    )
}

@Composable
private fun ClipboardSection(graph: AppGraph, ctx: android.content.Context, refresh: Int) {
    var on by remember { mutableStateOf(graph.settings.autoClipboard) }
    @Suppress("UNUSED_EXPRESSION") refresh // re-read the service state when the app comes back from system settings
    val serviceOn = ClipboardAccessibilityService.enabled(ctx)
    Section("Copy to Mac automatically") {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Send what I copy to my Mac automatically", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            Switch(checked = on, onCheckedChange = {
                on = it
                graph.settings.autoClipboard = it
                if (it && !ClipboardAccessibilityService.enabled(ctx)) openAccessibilitySettings(ctx)
            })
        }
        Text(
            "apnum uses an Accessibility service to notice when you copy text, then sends that text to your Mac. " +
                "Android will show a strong warning because Accessibility is powerful; apnum does not read your screen for anything else.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            "If Android says the setting is restricted, open apnum in App info, tap the three dots and choose Allow restricted settings.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            when {
                !on -> "Off"
                serviceOn -> "On. The apnum clipboard service is running."
                else -> "Waiting: turn on apnum clipboard in Accessibility settings."
            },
            style = MaterialTheme.typography.titleMedium,
            color = if (on && serviceOn) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (on && !serviceOn) OutlinedButton(onClick = { openAccessibilitySettings(ctx) }) { Text("Open Accessibility settings") }
    }
}

private fun openAccessibilitySettings(ctx: android.content.Context) {
    runCatching { ctx.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

@Composable
private fun UpdateSection(graph: AppGraph, ctx: android.content.Context) {
    val state by graph.updater.state.collectAsState()
    var auto by remember { mutableStateOf(graph.settings.autoUpdateCheck) }
    Section("Software update") {
        Text("Installed: ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.titleMedium)
        when (val s = state) {
            UpdateUi.Idle -> {}
            UpdateUi.Checking -> Text("Checking...", color = MaterialTheme.colorScheme.onSurfaceVariant)
            UpdateUi.UpToDate -> Text("apnum is up to date", color = MaterialTheme.colorScheme.primary)
            is UpdateUi.NoApk -> Text("Version ${s.release.tag.removePrefix("v")} exists, but it has no Android build yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            is UpdateUi.Failed -> Text(s.message, color = MaterialTheme.colorScheme.error)
            is UpdateUi.Available -> {
                Text("Version ${s.release.tag.removePrefix("v")} is available", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                if (s.release.notes.isNotBlank()) Text(s.release.notes.take(1200), style = MaterialTheme.typography.bodyMedium)
                if (!graph.updater.canInstall()) {
                    Text("To install it, allow apnum under Install unknown apps first.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedButton(onClick = { graph.updater.openInstallPermission() }) { Text("Open Install unknown apps") }
                }
                Button(onClick = { if (graph.updater.canInstall()) graph.updater.update(s.release) else graph.updater.openInstallPermission() }) { Text("Update now") }
            }
            is UpdateUi.Downloading -> {
                Text("Downloading version ${s.release.tag.removePrefix("v")}...", color = MaterialTheme.colorScheme.onSurfaceVariant)
                val f = s.fraction
                if (f == null) LinearProgressIndicator(Modifier.fillMaxWidth()) else LinearProgressIndicator(progress = { f }, modifier = Modifier.fillMaxWidth())
            }
            is UpdateUi.Installing -> Text("Waiting for Android to confirm the install.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        OutlinedButton(onClick = { graph.updater.check() }, enabled = state !is UpdateUi.Checking && state !is UpdateUi.Downloading) { Text("Check for updates") }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Check for updates automatically", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
            Switch(checked = auto, onCheckedChange = { auto = it; graph.settings.autoUpdateCheck = it })
        }
        Text(
            "This is the only time apnum uses the internet besides talking to your Mac. An update installs only if it is signed with the same key as the build you have now.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
