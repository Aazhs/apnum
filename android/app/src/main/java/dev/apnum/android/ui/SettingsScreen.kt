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
import dev.apnum.android.BuildConfig
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
fun SettingsScreen(mac: PairedMac?, deviceName: String, onUnpair: () -> Unit) {
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
