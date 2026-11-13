package dev.apnum.android.sync

import dev.apnum.android.link.bool
import dev.apnum.android.link.int
import dev.apnum.android.link.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.DayOfWeek
import java.time.Instant
import java.time.OffsetDateTime
import java.time.temporal.ChronoUnit
import java.util.UUID

/** A record that syncs: UUID id, a last-change time and a tombstone instead of deletion. */
interface SyncRecord {
    val id: String
    val updatedAt: Instant
    val deletedAt: Instant?
    val isDeleted get() = deletedAt != null
}

/** Reads and writes records in the Mac's exact JSON format. */
interface RecordCodec<T : SyncRecord> {
    fun toJson(r: T): JsonObject
    fun fromJson(o: JsonObject): T?
}

object Wire {
    /** `2026-11-13T10:00:00Z`: UTC, whole seconds. The Mac cannot decode fractional seconds. */
    fun date(i: Instant): String = i.truncatedTo(ChronoUnit.SECONDS).toString()

    fun parseDate(s: String?): Instant? {
        if (s.isNullOrBlank()) return null
        return runCatching { Instant.parse(s) }.getOrNull() ?: runCatching { OffsetDateTime.parse(s).toInstant() }.getOrNull()
    }

    /** The Mac writes ids in upper case; compare and store them in one form. */
    fun id(s: String?): String? = s?.trim()?.let { runCatching { UUID.fromString(it).toString().uppercase() }.getOrNull() }

    fun newId(): String = UUID.randomUUID().toString().uppercase()
}

data class AlarmRecord(
    override val id: String,
    val hour: Int,
    val minute: Int,
    val label: String = "",
    /** Lowercase full weekday names, as the Mac sends them. */
    val repeatDays: List<String> = emptyList(),
    val isEnabled: Boolean = true,
    val snoozeMinutes: Int = 9,
    val sound: String? = null,
    val createdAt: Instant,
    override val updatedAt: Instant,
    override val deletedAt: Instant? = null,
) : SyncRecord {
    val days: Set<DayOfWeek> get() = repeatDays.mapNotNull { n -> DayOfWeek.entries.firstOrNull { it.name.equals(n, true) } }.toSet()

    companion object {
        val dayNames: List<String> = DayOfWeek.entries.map { it.name.lowercase() }

        fun daysToNames(days: Set<DayOfWeek>): List<String> = DayOfWeek.entries.filter { it in days }.map { it.name.lowercase() }
    }
}

object AlarmCodec : RecordCodec<AlarmRecord> {
    override fun toJson(r: AlarmRecord) = buildJsonObject {
        put("id", r.id); put("hour", r.hour); put("minute", r.minute); put("label", r.label)
        put("repeatDays", buildJsonArray { r.repeatDays.forEach { add(JsonPrimitive(it)) } })
        put("isEnabled", r.isEnabled); put("snoozeMinutes", r.snoozeMinutes)
        r.sound?.let { put("sound", it) }
        put("createdAt", Wire.date(r.createdAt)); put("updatedAt", Wire.date(r.updatedAt))
        r.deletedAt?.let { put("deletedAt", Wire.date(it)) }
    }

    override fun fromJson(o: JsonObject): AlarmRecord? {
        val id = Wire.id(o.str("id")) ?: return null
        val updated = Wire.parseDate(o.str("updatedAt")) ?: return null
        val hour = o.int("hour")?.takeIf { it in 0..23 } ?: return null
        val minute = o.int("minute")?.takeIf { it in 0..59 } ?: return null
        return AlarmRecord(
            id, hour, minute, o.str("label").orEmpty(),
            (o["repeatDays"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content?.lowercase() }.orEmpty(),
            o.bool("isEnabled") ?: true, o.int("snoozeMinutes") ?: 9, o.str("sound"),
            Wire.parseDate(o.str("createdAt")) ?: updated, updated, Wire.parseDate(o.str("deletedAt")),
        )
    }
}

data class NoteRecord(
    override val id: String,
    val title: String = "",
    val body: String = "",
    val tags: List<String> = emptyList(),
    val pinned: Boolean = false,
    val createdAt: Instant,
    override val updatedAt: Instant,
    override val deletedAt: Instant? = null,
) : SyncRecord

object NoteCodec : RecordCodec<NoteRecord> {
    override fun toJson(r: NoteRecord) = buildJsonObject {
        put("id", r.id); put("title", r.title); put("body", r.body)
        put("tags", buildJsonArray { r.tags.forEach { add(JsonPrimitive(it)) } })
        put("pinned", r.pinned)
        put("createdAt", Wire.date(r.createdAt)); put("updatedAt", Wire.date(r.updatedAt))
        r.deletedAt?.let { put("deletedAt", Wire.date(it)) }
    }

    override fun fromJson(o: JsonObject): NoteRecord? {
        val id = Wire.id(o.str("id")) ?: return null
        val updated = Wire.parseDate(o.str("updatedAt")) ?: return null
        return NoteRecord(
            id, o.str("title").orEmpty(), o.str("body").orEmpty(),
            (o["tags"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty(),
            o.bool("pinned") ?: false, Wire.parseDate(o.str("createdAt")) ?: updated, updated, Wire.parseDate(o.str("deletedAt")),
        )
    }
}

/** Merge rule for the phone: the later `updatedAt` wins; on a tie the local record stays. */
object Merge {
    fun <T : SyncRecord> merge(local: Map<String, T>, incoming: Collection<T>): Map<String, T> {
        val out = LinkedHashMap(local)
        for (r in incoming) {
            val mine = out[r.id]
            if (mine == null || r.updatedAt.isAfter(mine.updatedAt)) out[r.id] = r
        }
        return out
    }
}

