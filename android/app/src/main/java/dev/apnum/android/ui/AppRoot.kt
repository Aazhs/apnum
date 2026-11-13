package dev.apnum.android.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import dev.apnum.android.AppGraph
import dev.apnum.android.sky.Sun
import dev.apnum.android.sky.SkyTheme
import kotlinx.coroutines.delay

enum class Tab(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Filled.Home),
    Alarms("Alarms", Icons.Filled.Notifications),
    Notes("Notes", Icons.Filled.Create),
    Permissions("Phone", Icons.Filled.Phone),
    Settings("Settings", Icons.Filled.Settings),
}

@Composable
fun AppRoot(graph: AppGraph, tab: Tab, onTab: (Tab) -> Unit, resumeCount: Int, startMessage: String?) {
    val link = graph.link
    val remote = graph.remote
    val mac by link.pairedMac.collectAsState()
    val state by link.connection.collectAsState()
    val demo by remote.demo.collectAsState()
    val location by remote.location.collectAsState()

    // The sun moves slowly: recompute the theme once a minute.
    val altitude by produceState(0.0, location) {
        while (true) {
            value = Sun.altitudeDegrees(System.currentTimeMillis(), location.first, location.second)
            delay(60_000)
        }
    }

    ApnumTheme(SkyTheme.forSunAltitude(altitude)) {
        val snackbar = remember { SnackbarHostState() }
        LaunchedEffect(Unit) { remote.messages.collect { snackbar.showSnackbar(it) } }
        LaunchedEffect(startMessage) { startMessage?.let { snackbar.showSnackbar(it) } }

        Scaffold(
            containerColor = androidx.compose.material3.MaterialTheme.colorScheme.background,
            snackbarHost = { SnackbarHost(snackbar) },
            bottomBar = {
                NavigationBar(containerColor = androidx.compose.material3.MaterialTheme.colorScheme.surface) {
                    Tab.entries.forEach {
                        NavigationBarItem(selected = tab == it, onClick = { onTab(it) }, icon = { Icon(it.icon, contentDescription = null) }, label = { Text(it.label, maxLines = 1) }, alwaysShowLabel = true)
                    }
                }
            },
        ) { padding ->
            val modifier = Modifier.fillMaxSize().padding(padding)
            androidx.compose.foundation.layout.Box(modifier) {
                when (tab) {
                    Tab.Home -> if (mac == null && !demo) PairingScreen(link) else HomeScreen(mac, state, remote, demo)
                    Tab.Alarms -> {
                        val status by graph.alarmStatus.collectAsState()
                        AlarmsScreen(graph.alarmRepo, status, dev.apnum.android.alarm.AlarmNotifications.canUseFullScreen(androidx.compose.ui.platform.LocalContext.current) || resumeCount < 0)
                    }
                    Tab.Notes -> {
                        val status by graph.noteStatus.collectAsState()
                        NotesScreen(graph.noteRepo, status)
                    }
                    Tab.Permissions -> PermissionsScreen(resumeCount) { graph.startMonitors() }
                    Tab.Settings -> SettingsScreen(mac, graph.store.identity().name) { link.unpair() }
                }
            }
        }
    }
}
