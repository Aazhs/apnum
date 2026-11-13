package dev.apnum.android.ui

import android.content.Context
import dev.apnum.android.link.ConnectionState
import dev.apnum.android.link.LinkClient
import dev.apnum.android.link.ToolException
import dev.apnum.android.link.bool
import dev.apnum.android.link.int
import dev.apnum.android.link.obj
import dev.apnum.android.link.str
import dev.apnum.android.sky.Sun
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

data class TimerItem(val id: String, val label: String, val state: String, val remainingSeconds: Double, val fetchedAtMs: Long) {
    val running get() = state == "running"
    fun remainingAt(nowMs: Long): Long =
        if (running) maxOf(0.0, remainingSeconds - (nowMs - fetchedAtMs) / 1000.0).toLong() else remainingSeconds.toLong()
}

/** What the home screen shows about the Mac, fetched through the same tool calls an agent would use. */
class MacRemote(context: Context, private val link: LinkClient, private val scope: CoroutineScope) {
    private val prefs = context.applicationContext.getSharedPreferences("apnum_ui", Context.MODE_PRIVATE)

    val volume = MutableStateFlow<Int?>(null)
    val muted = MutableStateFlow<Boolean?>(null)
    private val _timers = MutableStateFlow<List<TimerItem>>(emptyList())
    val timers: StateFlow<List<TimerItem>> = _timers.asStateFlow()
    /** Latitude and longitude the Mac uses for the sky; Pune until the Mac says otherwise. */
    private val _location = MutableStateFlow(
        prefs.getFloat("lat", Float.NaN).takeIf { !it.isNaN() }?.let { it.toDouble() to prefs.getFloat("lon", 0f).toDouble() }
            ?: (Sun.PUNE_LAT to Sun.PUNE_LON)
    )
    val location: StateFlow<Pair<Double, Double>> = _location.asStateFlow()

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val messages: SharedFlow<String> = _messages.asSharedFlow()

    /** Debug builds can show the home screen with sample data (`--ez demo true`). */
    val demo = MutableStateFlow(false)

    init {
        scope.launch {
            combine(link.connection, link.macTools) { c, t -> c == ConnectionState.Connected && t.isNotEmpty() }.collect { if (it) refreshAll() }
        }
        scope.launch {
            link.macEvents.collect { e ->
                if (e.topic == "changed") when (e.data.str("topic")) {
                    "timers" -> refreshTimers()
                }
            }
        }
    }

    /** The Mac's tool list; collect it in a composable so the screen follows what the Mac offers. */
    val tools: StateFlow<List<dev.apnum.android.link.ToolDescriptor>> get() = link.macTools

    fun has(tool: String) = link.macTools.value.any { it.name == tool }
    val hasRemote get() = link.macTools.value.any { it.name.startsWith("mac.") }

    /** Calls a Mac tool; the Mac's error message goes to the snackbar and null is returned. */
    suspend fun run(tool: String, input: JsonObject = JsonObject(emptyMap())): JsonElement? = try {
        link.callMac(tool, input)
    } catch (e: ToolException) {
        _messages.tryEmit(e.message ?: "The Mac could not do that.")
        null
    }

    fun act(tool: String, input: JsonObject = JsonObject(emptyMap()), after: suspend (JsonElement) -> Unit = {}): Job = scope.launch {
        run(tool, input)?.let { after(it) }
    }

    fun say(message: String) { _messages.tryEmit(message) }

    // region refresh

    fun refreshAll() {
        refreshVolume(); refreshTimers(); refreshSky()
    }

    fun refreshVolume() {
        if (!has("mac.volume.get")) return
        scope.launch { run("mac.volume.get")?.let(::readVolume) }
    }

    fun readVolume(o: JsonElement) {
        val obj = o as? JsonObject ?: return
        volume.value = obj.int("volume")
        muted.value = obj.bool("muted")
    }

    fun refreshTimers() {
        if (!has("timer.list")) return
        scope.launch {
            val out = run("timer.list") as? JsonObject ?: return@launch
            val now = System.currentTimeMillis()
            _timers.value = (out["timers"] as? JsonArray).objects().mapNotNull {
                TimerItem(it.str("id") ?: return@mapNotNull null, it.str("label").orEmpty(), it.str("state").orEmpty(), (it["remainingSeconds"] as? JsonPrimitive)?.doubleOrNull ?: 0.0, now)
            }
        }
    }

    /** `sky.now` carries the Mac's location as `location: {latitude, longitude}`. */
    fun refreshSky() {
        if (!has("sky.now")) return
        scope.launch {
            val loc = (run("sky.now") as? JsonObject)?.obj("location") ?: return@launch
            val lat = (loc["latitude"] as? JsonPrimitive)?.doubleOrNull ?: return@launch
            val lon = (loc["longitude"] as? JsonPrimitive)?.doubleOrNull ?: return@launch
            _location.value = lat to lon
            prefs.edit().putFloat("lat", lat.toFloat()).putFloat("lon", lon.toFloat()).apply()
        }
    }

    // endregion

    fun loadDemo() {
        demo.value = true
        volume.value = 42; muted.value = false
        val now = System.currentTimeMillis()
        _timers.value = listOf(TimerItem("1", "Tea", "running", 214.0, now), TimerItem("2", "", "paused", 1500.0, now))
    }

    private fun JsonArray?.objects(): List<JsonObject> = this?.mapNotNull { it as? JsonObject } ?: emptyList()
}
