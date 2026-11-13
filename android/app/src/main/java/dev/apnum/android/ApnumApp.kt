package dev.apnum.android

import android.app.Application
import android.content.Context
import android.os.Build
import dev.apnum.android.link.DeviceInfo
import dev.apnum.android.link.LinkClient
import dev.apnum.android.link.NsdDiscovery
import dev.apnum.android.link.PrefsStore
import dev.apnum.android.link.ToolRegistry
import dev.apnum.android.phone.BatteryMonitor
import dev.apnum.android.phone.CallMonitor
import dev.apnum.android.phone.PhoneTools
import dev.apnum.android.phone.Perms
import dev.apnum.android.phone.Ringer
import dev.apnum.android.ui.MacRemote
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Everything the process shares: the link, the phone tools and the Mac remote state. */
class AppGraph(app: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val store = PrefsStore(app)
    private val identity = store.identity()
    val registry = ToolRegistry { Perms.has(app, it) }
    val ringer = Ringer(app, scope)
    val calls: CallMonitor = CallMonitor(app) { state, number ->
        link.sendEvent("call.state", buildJsonObject {
            put("state", state); put("number", number); put("contactName", phoneTools.contactName(number))
        })
    }
    val battery: BatteryMonitor = BatteryMonitor(app) { percent, charging ->
        link.sendEvent("battery", buildJsonObject { put("percent", percent); put("charging", charging) })
    }
    val phoneTools: PhoneTools = PhoneTools(app, calls, ringer)
    val link: LinkClient = LinkClient(
        identity, store, registry,
        DeviceInfo(identity.deviceId, identity.name, "android", BuildConfig.VERSION_NAME, "Android ${Build.VERSION.RELEASE}"),
        NsdDiscovery(app), scope,
    )
    val remote = MacRemote(app, link, scope)

    init {
        phoneTools.registerAll(registry)
    }

    /** Call after the app starts and after a permission is granted. */
    fun startMonitors() {
        calls.start()
        battery.start()
        link.refreshTools()
    }
}

class ApnumApp : Application() {
    val graph by lazy { AppGraph(this) }

    companion object {
        fun graph(context: Context): AppGraph = (context.applicationContext as ApnumApp).graph
    }
}
