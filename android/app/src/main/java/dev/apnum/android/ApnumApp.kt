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
import dev.apnum.android.alarm.AlarmController
import dev.apnum.android.alarm.AlarmRepository
import dev.apnum.android.alarm.AlarmScheduler
import dev.apnum.android.alarm.AndroidRingEnvironment
import dev.apnum.android.alarm.MacRingingItem
import dev.apnum.android.notes.NoteRepository
import dev.apnum.android.sync.AlarmCodec
import dev.apnum.android.sync.NoteCodec
import dev.apnum.android.sync.RecordSync
import dev.apnum.android.sync.SyncCoordinator
import dev.apnum.android.sync.SyncJob
import dev.apnum.android.sync.SyncResult
import dev.apnum.android.sync.SyncStore
import dev.apnum.android.link.ConnectionState
import dev.apnum.android.link.str
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.io.File
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

    // Alarms and notes live on the phone (and work offline); they sync with the Mac through alarm.sync and note.sync.
    val alarmStore: SyncStore<dev.apnum.android.sync.AlarmRecord> = SyncStore(File(app.filesDir, "alarms.json"), AlarmCodec)
    val alarmRepo: AlarmRepository = AlarmRepository(alarmStore, File(app.filesDir, "alarm-snoozes.json"), onSnoozeChanged = { alarmScheduler.reschedule() })
    val alarmScheduler: AlarmScheduler = AlarmScheduler(app, alarmRepo)
    val alarmController: AlarmController = AlarmController(alarmRepo, AndroidRingEnvironment(app, link) { alarmScheduler }, scope)
    val noteStore: SyncStore<dev.apnum.android.sync.NoteRecord> = SyncStore(File(app.filesDir, "notes.json"), NoteCodec)
    val noteRepo: NoteRepository = NoteRepository(noteStore)

    /** One short line per synced thing for the Alarms and Notes screens. */
    val alarmStatus = MutableStateFlow("")
    val noteStatus = MutableStateFlow("")

    init {
        phoneTools.registerAll(registry)
        link.setLocalNetworkAllowed(Build.VERSION.SDK_INT < 37 || Perms.has(app, "android.permission.ACCESS_LOCAL_NETWORK"))
        scope.launch { alarmStore.live.collect { alarmScheduler.reschedule() } }
        scope.launch {
            link.macEvents.collect { e -> if (e.topic == "ringing") alarmController.onMacRinging(MacRingingItem.parse(e.data)) }
        }
        val available = combine(link.connection, link.macTools) { c, t -> c == ConnectionState.Connected && t.isNotEmpty() }.distinctUntilChanged()
        val alarmSync = RecordSync(alarmStore, AlarmCodec, "alarm.sync", link)
        val noteSync = RecordSync(noteStore, NoteCodec, "note.sync", link)
        SyncCoordinator(
            scope,
            listOf(SyncJob("alarms", alarmStore.localEdits) { alarmSync.sync() }, SyncJob("notes", noteStore.localEdits) { noteSync.sync() }),
            available,
            link.macEvents.filter { it.topic == "changed" }.map { it.data.str("topic").orEmpty() },
            onResult = { topic, r ->
                val text = when (r) {
                    is SyncResult.Synced -> "Synced with Mac"
                    SyncResult.Offline -> "Offline, will sync later"
                    SyncResult.Unsupported -> "Mac cannot sync yet"
                    is SyncResult.Failed -> "Sync failed, retrying"
                }
                if (r is SyncResult.Synced && r.skipped > 0) android.util.Log.w("apnum", "$topic sync: the Mac skipped ${r.skipped} records")
                (if (topic == "alarms") alarmStatus else noteStatus).value = text
            },
        ).start()
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
