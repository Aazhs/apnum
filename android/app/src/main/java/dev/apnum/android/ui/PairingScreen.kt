package dev.apnum.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import dev.apnum.android.link.LinkClient
import dev.apnum.android.link.NsdDiscovery
import dev.apnum.android.link.PairUri
import dev.apnum.android.link.PairUriException
import dev.apnum.android.link.PairingState

@Composable
fun PairingScreen(link: LinkClient) {
    val ctx = LocalContext.current
    val state by link.pairing.collectAsState()
    var showCode by rememberSaveable { mutableStateOf(false) }
    var address by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var scanError by remember { mutableStateOf<String?>(null) }

    val discovery = remember { NsdDiscovery(ctx) }
    val found by discovery.found.collectAsState()
    DisposableEffect(Unit) {
        discovery.start()
        onDispose { discovery.stop() }
    }
    // Prefill the address once a Mac shows up, unless the user already typed one.
    val first = found.firstOrNull()
    if (address.isEmpty() && first != null) address = "${first.host}:${first.port}"

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Spacer(Modifier.height(24.dp))
        Text("Pair with your Mac", style = MaterialTheme.typography.displaySmall)
        Text(
            "On your Mac, open apnum, then Phone, then Pair a phone. It shows a code to scan.",
            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))

        Button(
            onClick = {
                scanError = null
                val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                GmsBarcodeScanning.getClient(ctx, options).startScan()
                    .addOnSuccessListener { barcode ->
                        try {
                            link.pair(PairUri.parse(barcode.rawValue.orEmpty()))
                        } catch (e: PairUriException) {
                            scanError = e.message
                        }
                    }
                    .addOnFailureListener { scanError = "The scanner could not start. You can enter the code instead." }
            },
            modifier = Modifier.fillMaxWidth().height(56.dp),
        ) { Text("Scan the code on your Mac") }

        OutlinedButton(onClick = { showCode = !showCode }, modifier = Modifier.fillMaxWidth().height(56.dp)) { Text("Enter code instead") }

        scanError?.let { Text(it, color = MaterialTheme.colorScheme.error) }

        if (showCode) {
            if (found.isNotEmpty()) {
                Text("Macs on this network", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    found.forEach { AssistChip(onClick = { address = "${it.host}:${it.port}" }, label = { Text(it.name) }) }
                }
            }
            OutlinedTextField(
                value = address, onValueChange = { address = it }, label = { Text("Mac address") },
                supportingText = { Text("Like 192.168.1.20 or 192.168.1.20:47800") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = code, onValueChange = { code = it.filter(Char::isDigit).take(8) }, label = { Text("8-digit code") },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth(),
            )
            val parsed = PairUri.parseAddress(address)
            val normalized = PairUri.normalizeCode(code)
            Button(
                onClick = { link.pairWithCode(parsed!!.first, parsed.second, normalized!!) },
                enabled = parsed != null && normalized != null && state !is PairingState.Connecting,
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) { Text("Connect") }
        }

        when (val s = state) {
            PairingState.Connecting -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                CircularProgressIndicator(Modifier.height(24.dp))
                Text("Connecting to your Mac")
            }
            is PairingState.Failed -> {
                Text(s.message, color = MaterialTheme.colorScheme.error)
                TextButton(onClick = { link.dismissPairingResult() }) { Text("Dismiss") }
            }
            else -> Unit
        }
    }

    (state as? PairingState.ConfirmSafetyNumber)?.let { s ->
        val spaced = s.number.chunked(3).joinToString(" ")
        AlertDialog(
            onDismissRequest = { link.confirmSafetyNumber(false) },
            title = { Text("Check the safety number") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(spaced, style = MaterialTheme.typography.displayMedium)
                    Text("Your Mac shows a 6-digit number too. Only continue if they match.")
                }
            },
            confirmButton = { Button(onClick = { link.confirmSafetyNumber(true) }) { Text("They match") } },
            dismissButton = { TextButton(onClick = { link.confirmSafetyNumber(false) }) { Text("They differ") } },
        )
    }
}
