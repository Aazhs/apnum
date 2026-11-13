package dev.apnum.android.sync

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.time.Instant

/**
 * Local records (tombstones included), the Mac's last `serverTime` and the ids edited here since the last
 * successful sync. Kept as one small JSON file, rewritten atomically. [file] null keeps everything in memory.
 */
class SyncStore<T : SyncRecord>(private val file: File?, private val codec: RecordCodec<T>) {
    private var records = LinkedHashMap<String, T>()
    private val dirty = LinkedHashSet<String>()
    var since: Instant? = null
        private set

    private val _live = MutableStateFlow<List<T>>(emptyList())
    /** Records that are not deleted. */
    val live: StateFlow<List<T>> = _live.asStateFlow()

    private val _edits = MutableSharedFlow<Unit>(extraBufferCapacity = 8)
    /** Emits after every local edit (not after a merge from the Mac). */
    val localEdits: SharedFlow<Unit> = _edits.asSharedFlow()

    private val _merged = MutableSharedFlow<Unit>(extraBufferCapacity = 8)
    /** Emits after a sync brought changes in from the Mac. */
    val mergedFromMac: SharedFlow<Unit> = _merged.asSharedFlow()

    init { load() }

    @Synchronized fun get(id: String): T? = records[id]
    @Synchronized fun all(): List<T> = records.values.toList()

    /** Saves a local edit and marks it for the next sync. */
    fun put(r: T) {
        synchronized(this) {
            records[r.id] = r
            dirty += r.id
            publishAndSave()
        }
        _edits.tryEmit(Unit)
    }

    @Synchronized fun dirtyRecords(): List<T> = dirty.mapNotNull { records[it] }

    /**
     * Applies the Mac's answer. [pushed] are the records that were sent; they stop being dirty unless they were
     * edited again while the call was in flight.
     */
    fun applySync(incoming: List<T>, pushed: List<T>, serverTime: Instant?) {
        var changed = false
        synchronized(this) {
            val before = records
            records = LinkedHashMap(Merge.merge(records, incoming))
            changed = incoming.any { before[it.id] !== records[it.id] }
            for (p in pushed) if (records[p.id]?.updatedAt == p.updatedAt) dirty -= p.id
            if (serverTime != null) since = serverTime
            publishAndSave()
        }
        if (changed) _merged.tryEmit(Unit)
    }

    private fun publishAndSave() {
        _live.value = records.values.filter { !it.isDeleted }
        val f = file ?: return
        runCatching {
            val o = buildJsonObject {
                since?.let { put("since", Wire.date(it)) }
                put("dirty", JsonArray(dirty.map { JsonPrimitive(it) }))
                put("records", JsonArray(records.values.map { codec.toJson(it) }))
            }
            f.parentFile?.mkdirs()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(Json.encodeToString(JsonObject.serializer(), o))
            if (!tmp.renameTo(f)) { f.writeText(tmp.readText()); tmp.delete() }
        }
    }

    private fun load() {
        val f = file?.takeIf { it.exists() } ?: return
        runCatching {
            val o = Json.parseToJsonElement(f.readText()).jsonObject
            since = Wire.parseDate((o["since"] as? JsonPrimitive)?.content)
            (o["dirty"] as? JsonArray)?.forEach { (it as? JsonPrimitive)?.content?.let(dirty::add) }
            (o["records"] as? JsonArray)?.forEach { e -> (e as? JsonObject)?.let(codec::fromJson)?.let { records[it.id] = it } }
        }
        _live.value = records.values.filter { !it.isDeleted }
    }
}
