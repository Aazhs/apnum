package dev.apnum.android.alarm

import dev.apnum.android.link.bool
import dev.apnum.android.link.str
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** An alarm that is ringing on this phone right now. */
data class Ringing(val id: String, val label: String, val hour: Int, val minute: Int, val canSnooze: Boolean = true)

/** One entry of the Mac's `ringing` event. */
data class MacRingingItem(val id: String, val kind: String, val title: String, val body: String, val canSnooze: Boolean) {
    companion object {
        fun parse(data: JsonObject): List<MacRingingItem> = ((data["items"] as? JsonArray) ?: JsonArray(emptyList())).mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            MacRingingItem(o.str("id")?.uppercase() ?: return@mapNotNull null, o.str("kind") ?: "alarm", o.str("title").orEmpty(), o.str("body").orEmpty(), o.bool("canSnooze") ?: true)
        }
    }
}

/** What the controller needs from the outside world. */
interface RingEnvironment {
    /** Calls a Mac tool; failures are ignored by the caller (the phone may be offline). */
    suspend fun callMac(tool: String, input: JsonObject)
    fun sendEvent(topic: String, data: JsonObject)
    /** Make sure the ringing service is running (it plays sound and shows the full-screen screen). */
    fun ensureServiceRunning()
    fun rescheduleAlarms()
    fun showTimers(items: List<MacRingingItem>)
    fun showMissed(r: Ringing)
}

/**
 * Starts, stops and snoozes ringing on this phone and keeps the Mac informed:
 * the user's action on the phone is sent to the Mac, and the Mac's `ringing` event can silence the phone.
 */
class AlarmController(
    private val repo: AlarmRepository,
    private val env: RingEnvironment,
    private val scope: CoroutineScope,
    private val timeoutMs: Long = 10 * 60_000L,
) {
    private val coordination = RingingCoordinator()
    private val _ringing = MutableStateFlow<List<Ringing>>(emptyList())
    val ringing: StateFlow<List<Ringing>> = _ringing.asStateFlow()
    private val timeouts = HashMap<String, Job>()

    /** The system woke us at [now]: ring whatever fell due. */
    fun ringDue(now: java.time.Instant, zone: java.time.ZoneId = java.time.ZoneId.systemDefault()) {
        val ids = AlarmLogic.due(repo.store.live.value, repo.snoozedUntil(), now, zone)
        val fresh = ids.filter { !repo.recentlyRang(it) }
        if (fresh.isEmpty()) env.rescheduleAlarms() else fresh.forEach { ring(it) }
    }

    /** The scheduled time arrived. */
    fun ring(id: String) {
        val a = repo.get(id) ?: return env.rescheduleAlarms()
        repo.clearSnooze(a.id)
        repo.ringStarted(a.id)
        if (_ringing.value.none { it.id == a.id }) {
            _ringing.value = _ringing.value + Ringing(a.id, a.label, a.hour, a.minute)
            coordination.localStarted(a.id)
            timeouts[a.id] = scope.launch {
                delay(timeoutMs)
                if (_ringing.value.any { it.id == a.id }) end(a.id, tellMac = true, action = "alarm.stop", missed = true)
            }
        }
        env.ensureServiceRunning()
        env.rescheduleAlarms()
        announce()
    }

    fun stop(id: String) = end(id, tellMac = true, action = "alarm.stop")

    fun snooze(id: String) {
        repo.snooze(id)
        end(id, tellMac = true, action = "alarm.snooze", disable = false)
    }

    fun stopAll() = _ringing.value.forEach { stop(it.id) }

    /** The Mac's `ringing` event. */
    fun onMacRinging(items: List<MacRingingItem>) {
        val alarmIds = items.filter { it.kind == "alarm" }.map { it.id }.toSet()
        runCatching { android.util.Log.d("apnum", "mac ringing: ${alarmIds.size} alarms, ${items.size - alarmIds.size} others; local ${_ringing.value.size}") }
        for (id in coordination.onMacRinging(alarmIds)) end(id, tellMac = false, action = "")
        env.showTimers(items.filter { it.kind == "timer" })
    }

    private fun end(id: String, tellMac: Boolean, action: String, missed: Boolean = false, disable: Boolean = true) {
        val r = _ringing.value.firstOrNull { it.id == id }
        runCatching { android.util.Log.d("apnum", "ring end: tellMac=$tellMac action=$action missed=$missed") }
        timeouts.remove(id)?.cancel()
        if (disable) repo.ringEnded(id)
        coordination.localEnded(id)
        _ringing.value = _ringing.value.filter { it.id != id }
        if (tellMac && action.isNotEmpty()) scope.launch { runCatching { env.callMac(action, buildJsonObject { put("id", id) }) } }
        if (missed && r != null) env.showMissed(r)
        env.rescheduleAlarms()
        announce()
    }

    private fun announce() {
        env.sendEvent("phone.ringing", buildJsonObject {
            put("ids", JsonArray(_ringing.value.map { JsonPrimitive(it.id) }))
        })
    }
}
