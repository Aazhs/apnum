package dev.apnum.android

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import dev.apnum.android.link.PairUri
import dev.apnum.android.link.PairUriException
import dev.apnum.android.ui.AppRoot
import dev.apnum.android.ui.Tab
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private var tab by mutableStateOf(Tab.Home)
    private var resumeCount by mutableIntStateOf(0)
    private var message by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val graph = ApnumApp.graph(this)
        handle(intent, graph)
        // Android 17 gates local network access behind a runtime permission; ask up front.
        if (Build.VERSION.SDK_INT >= 37 && !dev.apnum.android.phone.Perms.has(this, LOCAL_NETWORK)) {
            registerForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { graph.link.networkChanged(false) }
                .launch(LOCAL_NETWORK)
        }
        // Keep the link alive in the background once a Mac is paired.
        lifecycleScope.launch { graph.link.pairedMac.filterNotNull().collect { runCatching { LinkService.start(this@MainActivity) } } }
        setContent {
            AppRoot(graph, tab, { tab = it }, resumeCount, message)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent, ApnumApp.graph(this))
    }

    override fun onResume() {
        super.onResume()
        resumeCount++
        ApnumApp.graph(this).startMonitors()
    }

    private companion object {
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    }

    private fun handle(intent: Intent?, graph: AppGraph) {
        val data = intent?.dataString
        if (PairUri.looksLikePairUri(data)) {
            tab = Tab.Home
            try {
                graph.link.pair(PairUri.parse(data!!))
            } catch (e: PairUriException) {
                message = e.message
            }
        }
        // Debug builds: `am start -n dev.apnum.android/.MainActivity --ez demo true --es tab permissions`.
        if (BuildConfig.DEBUG) {
            if (intent?.getBooleanExtra("demo", false) == true) graph.remote.loadDemo()
            intent?.getStringExtra("tab")?.let { name -> Tab.entries.firstOrNull { it.name.equals(name, true) }?.let { tab = it } }
        }
    }
}
