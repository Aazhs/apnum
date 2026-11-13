package dev.apnum.android.alarm

import dev.apnum.android.sync.AlarmRecord
import dev.apnum.android.sync.SyncStore
import dev.apnum.android.sync.Wire
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.time.DayOfWeek
import java.time.Instant

/** The phone's alarms. Edits go to the [store] (and so to the Mac at the next sync); snoozes stay on this phone. */
class AlarmRepository(
    val store: SyncStore<AlarmRecord>,
    private val snoozeFile: File?,
    private val clock: () -> Instant = { Instant.now() },
    private val onSnoozeChanged: () -> Unit = {},
) {
    private val snoozes = HashMap<String, Instant>()

    init {
        runCatching {
            snoozeFile?.takeIf { it.exists() }?.let { f ->
                Json.parseToJsonElement(f.readText()).jsonObject.forEach { (k, v) ->
                    (v as? JsonPrimitive)?.content?.toLongOrNull()?.let { snoozes[k] = Instant.ofEpochMilli(it) }
                }
            }
        }
    }

    fun get(id: String): AlarmRecord? = store.get(id.uppercase())?.takeIf { !it.isDeleted }

    fun create(hour: Int, minute: Int, label: String, days: Set<DayOfWeek>, snoozeMinutes: Int): AlarmRecord {
        val now = clock()
        val a = AlarmRecord(Wire.newId(), hour, minute, label.trim(), AlarmRecord.daysToNames(days), true, snoozeMinutes, null, now, now)
        store.put(a)
        return a
    }

    fun update(id: String, hour: Int, minute: Int, label: String, days: Set<DayOfWeek>, snoozeMinutes: Int, enabled: Boolean = true) {
        val old = get(id) ?: return
        store.put(old.copy(hour = hour, minute = minute, label = label.trim(), repeatDays = AlarmRecord.daysToNames(days),
            snoozeMinutes = snoozeMinutes, isEnabled = enabled, updatedAt = clock()))
        clearSnooze(id)
    }

    fun setEnabled(id: String, on: Boolean) {
        val old = get(id) ?: return
        if (old.isEnabled == on) return
        store.put(old.copy(isEnabled = on, updatedAt = clock()))
        if (!on) clearSnooze(id)
    }

    /** Tombstone: the record stays so the deletion reaches the Mac. */
    fun delete(id: String) {
        val old = get(id) ?: return
        val now = clock()
        store.put(old.copy(isEnabled = false, updatedAt = now, deletedAt = now))
        clearSnooze(id)
    }

    /** Local only (never synced): when each alarm last started ringing, so a wake-up inside the due window cannot ring it twice. */
    private val rangAt = HashMap<String, Instant>()

    /** Starting to ring changes nothing that syncs; it only remembers this occurrence rang. */
    @Synchronized fun ringStarted(id: String) { rangAt[id] = clock() }

    @Synchronized fun recentlyRang(id: String, withinSeconds: Long = 45): Boolean =
        rangAt[id]?.let { clock().isBefore(it.plusSeconds(withinSeconds)) } == true

    /** The ring has ended (stopped here, stopped on the Mac, or timed out): a one-time alarm turns itself off. Snooze does not call this. */
    fun ringEnded(id: String) {
        val a = get(id) ?: return
        if (a.repeatDays.isEmpty() && a.isEnabled) store.put(a.copy(isEnabled = false, updatedAt = clock()))
    }

    @Synchronized fun snoozedUntil(): Map<String, Instant> = HashMap(snoozes)

    fun snooze(id: String) {
        val a = get(id) ?: return
        setSnooze(id, clock().plusSeconds(a.snoozeMinutes.coerceAtLeast(1) * 60L))
    }

    @Synchronized fun setSnooze(id: String, until: Instant) { snoozes[id] = until; saveSnoozes(); onSnoozeChanged() }

    @Synchronized fun clearSnooze(id: String) { if (snoozes.remove(id) != null) { saveSnoozes(); onSnoozeChanged() } }

    private fun saveSnoozes() {
        val f = snoozeFile ?: return
        runCatching {
            f.parentFile?.mkdirs()
            val o = buildJsonObject { snoozes.forEach { (k, v) -> put(k, v.toEpochMilli().toString()) } }
            f.writeText(Json.encodeToString(JsonObject.serializer(), o))
        }
    }
}
