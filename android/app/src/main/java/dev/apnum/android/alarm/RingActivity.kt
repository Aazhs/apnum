package dev.apnum.android.alarm

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.apnum.android.ApnumApp
import dev.apnum.android.sky.SkyTheme
import dev.apnum.android.ui.ApnumTheme

/** Shows over the lock screen and turns the screen on while an alarm rings. */
class RingActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enableEdgeToEdge()
        val controller = ApnumApp.graph(this).alarmController
        setContent {
            ApnumTheme(SkyTheme.forSunAltitude(-20.0)) {
                val ringing by controller.ringing.collectAsState()
                LaunchedEffect(ringing.isEmpty()) { if (ringing.isEmpty()) finish() }
                val r = ringing.firstOrNull()
                androidx.compose.material3.Surface(color = MaterialTheme.colorScheme.background, contentColor = MaterialTheme.colorScheme.onBackground) {
                Column(
                    Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).padding(horizontal = 28.dp, vertical = 64.dp),
                    verticalArrangement = Arrangement.SpaceBetween, horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Spacer(Modifier.height(64.dp))
                        Text(r?.let { "%02d:%02d".format(it.hour, it.minute) } ?: "", fontSize = 96.sp, style = MaterialTheme.typography.displayLarge)
                        Text(r?.label?.ifBlank { "Alarm" } ?: "", style = MaterialTheme.typography.headlineMedium, textAlign = TextAlign.Center)
                        if (ringing.size > 1) Text("${ringing.size - 1} more ringing", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        if (r?.canSnooze != false) FilledTonalButton(
                            onClick = { r?.let { controller.snooze(it.id) } }, modifier = Modifier.fillMaxWidth().height(64.dp),
                        ) { Text("Snooze", fontSize = 20.sp) }
                        Button(onClick = { controller.stopAll() }, modifier = Modifier.fillMaxWidth().height(72.dp)) { Text("Stop", fontSize = 22.sp) }
                    }
                }
                }
            }
        }
    }
}
