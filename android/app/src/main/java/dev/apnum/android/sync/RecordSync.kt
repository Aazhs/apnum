package dev.apnum.android.sync

import dev.apnum.android.link.str
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** What sync needs from the link: a connection flag, the Mac's tool names and a way to call one. */
interface MacCaller {
    val isConnected: Boolean
    fun hasTool(name: String): Boolean
    suspend fun call(tool: String, input: JsonObject): JsonElement
}

sealed interface SyncResult {
    data class Synced(val pushed: Int, val pulled: Int, val skipped: Int) : SyncResult
    /** Not connected: local data is kept and pushed at the next connect. */
    data object Offline : SyncResult
    /** The Mac is older and has no sync tool: local data is kept. */
    data object Unsupported : SyncResult
    data class Failed(val message: String) : SyncResult
}

/** One round of `alarm.sync` or `note.sync`: push the records edited here, merge what comes back. */
class RecordSync<T : SyncRecord>(
    private val store: SyncStore<T>,
    private val codec: RecordCodec<T>,
    val tool: String,
    private val mac: MacCaller,
) {
    private val lock = Mutex()

    suspend fun sync(): SyncResult = lock.withLock {
        if (!mac.isConnected) return SyncResult.Offline
        if (!mac.hasTool(tool)) return SyncResult.Unsupported
        val pushed = store.dirtyRecords()
        val input = buildJsonObject {
            put("records", JsonArray(pushed.map { codec.toJson(it) }))
            store.since?.let { put("since", Wire.date(it)) }
        }
        val out = try {
            mac.call(tool, input) as? JsonObject ?: return SyncResult.Failed("The Mac sent an unexpected answer.")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            return SyncResult.Failed(e.message ?: "Sync failed.")
        }
        val incoming = ((out["records"] as? JsonArray) ?: JsonArray(emptyList())).mapNotNull { (it as? JsonObject)?.let(codec::fromJson) }
        store.applySync(incoming, pushed, Wire.parseDate(out.str("serverTime")))
        val skipped = (out["skipped"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0
        SyncResult.Synced(pushed.size, incoming.size, skipped)
    }
}
