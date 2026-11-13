package dev.apnum.android

import dev.apnum.android.link.LinkErrors
import dev.apnum.android.link.ToolException
import dev.apnum.android.link.ErrorCode
import dev.apnum.android.sync.AlarmCodec
import dev.apnum.android.sync.AlarmRecord
import dev.apnum.android.sync.MacCaller
import dev.apnum.android.sync.Merge
import dev.apnum.android.sync.NoteCodec
import dev.apnum.android.sync.NoteRecord
import dev.apnum.android.sync.RecordSync
import dev.apnum.android.sync.SyncCoordinator
import dev.apnum.android.sync.SyncJob
import dev.apnum.android.sync.SyncResult
import dev.apnum.android.sync.SyncStore
import dev.apnum.android.sync.Wire
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant

private fun i(s: String) = Instant.parse(s)

private fun alarm(id: String, updated: String, hour: Int = 7, label: String = "", deleted: String? = null) =
    AlarmRecord(id, hour, 30, label, listOf("monday", "friday"), true, 9, null, i("2026-01-01T06:00:00Z"), i(updated), deleted?.let(::i))

private const val ID1 = "B696E7C2-1E97-46BE-B308-1FFD34DD7CD6"
private const val ID2 = "71AB013D-8DBB-44CF-A1A2-F01BDAC7946E"

/** A pretend Mac with the merge rules of `alarm.sync`: later updatedAt wins, ties go to the incoming record. */
private class FakeMac(var connected: Boolean = true, var tools: Set<String> = setOf("alarm.sync", "note.sync")) : MacCaller {
    val alarms = LinkedHashMap<String, AlarmRecord>()
    var serverTime = "2026-11-13T10:00:00Z"
    var failNext = 0
    val calls = mutableListOf<JsonObject>()
    override val isConnected get() = connected
    override fun hasTool(name: String) = name in tools
    override suspend fun call(tool: String, input: JsonObject): JsonElement {
        calls += input
        if (failNext > 0) { failNext--; throw ToolException(ErrorCode.Unavailable, "The connection to the Mac was lost.") }
        val since = (input["since"] as? JsonPrimitive)?.content?.let(::i)
        for (e in input["records"]!!.jsonArray) {
            val r = AlarmCodec.fromJson(e.jsonObject)!!
            val mine = alarms[r.id]
            if (mine == null || !r.updatedAt.isBefore(mine.updatedAt)) alarms[r.id] = r
        }
        val out = alarms.values.filter { since == null || it.updatedAt.isAfter(since) }
        return buildJsonObject {
            put("records", JsonArray(out.map { AlarmCodec.toJson(it) }))
            put("serverTime", serverTime); put("skipped", 0)
        }
    }
}

class RecordsTest {
    @Test fun alarmRoundTripsInTheMacsFormat() {
        val mac = Json.parseToJsonElement(
            """{"createdAt":"2026-01-01T06:00:00Z","hour":7,"id":"B696E7C2-1E97-46BE-B308-1FFD34DD7CD6","isEnabled":true,"label":"Gym","minute":30,"repeatDays":["monday","friday"],"snoozeMinutes":9,"updatedAt":"2026-01-02T06:00:00Z"}"""
        ).jsonObject
        val a = AlarmCodec.fromJson(mac)!!
        assertEquals(ID1, a.id); assertEquals(7, a.hour); assertEquals("Gym", a.label)
        assertEquals(i("2026-01-02T06:00:00Z"), a.updatedAt); assertNull(a.deletedAt); assertNull(a.sound)
        val back = AlarmCodec.toJson(a)
        assertEquals("2026-01-02T06:00:00Z", (back["updatedAt"] as JsonPrimitive).content)
        assertFalse(back.containsKey("deletedAt")); assertFalse(back.containsKey("sound"))
        assertEquals(a, AlarmCodec.fromJson(back))
    }

    @Test fun tombstoneKeepsDeletedAt() {
        val a = alarm(ID1, "2026-01-03T00:00:00Z", deleted = "2026-01-03T00:00:00Z")
        val j = AlarmCodec.toJson(a)
        assertEquals("2026-01-03T00:00:00Z", (j["deletedAt"] as JsonPrimitive).content)
        assertTrue(AlarmCodec.fromJson(j)!!.isDeleted)
    }

    @Test fun idsAcceptEitherCaseAndAreStoredUpper() {
        val o = AlarmCodec.toJson(alarm(ID1, "2026-01-03T00:00:00Z")).let { JsonObject(it + ("id" to JsonPrimitive(ID1.lowercase()))) }
        assertEquals(ID1, AlarmCodec.fromJson(o)!!.id)
        assertEquals(ID1, Wire.id(" ${ID1.lowercase()} "))
        assertNull(Wire.id("not-a-uuid"))
    }

    @Test fun datesAreWholeSecondsUtcWithZ() {
        assertEquals("2026-11-13T10:00:00Z", Wire.date(i("2026-11-13T10:00:00.987654Z")))
        assertEquals(i("2026-11-13T10:00:00Z"), Wire.parseDate("2026-11-13T10:00:00.250Z")?.let { Instant.ofEpochSecond(it.epochSecond) })
        assertEquals(i("2026-11-13T10:00:00Z"), Wire.parseDate("2026-11-13T15:30:00+05:30"))
        assertNull(Wire.parseDate("yesterday"))
        val j = AlarmCodec.toJson(alarm(ID1, "2026-11-13T10:00:00Z").copy(createdAt = i("2026-11-13T09:00:00.5Z")))
        assertEquals("2026-11-13T09:00:00Z", (j["createdAt"] as JsonPrimitive).content)
    }

    @Test fun noteRoundTrip() {
        val mac = Json.parseToJsonElement(
            """{"body":"# Plan\n- one","createdAt":"2026-01-01T06:00:00Z","id":"71AB013D-8DBB-44CF-A1A2-F01BDAC7946E","pinned":true,"tags":["work","home"],"title":"Plan","updatedAt":"2026-01-02T06:00:00Z"}"""
        ).jsonObject
        val n = NoteCodec.fromJson(mac)!!
        assertEquals("# Plan\n- one", n.body); assertEquals(listOf("work", "home"), n.tags); assertTrue(n.pinned)
        assertEquals(mac, NoteCodec.toJson(n))
    }

    @Test fun badRecordsAreSkipped() {
        assertNull(AlarmCodec.fromJson(buildJsonObject { put("id", ID1) }))
        assertNull(AlarmCodec.fromJson(JsonObject(AlarmCodec.toJson(alarm(ID1, "2026-01-01T00:00:00Z")) + ("hour" to JsonPrimitive(30)))))
    }
}

class MergeTest {
    private fun map(vararg a: AlarmRecord) = a.associateBy { it.id }

    @Test fun newerWins() {
        val local = map(alarm(ID1, "2026-01-02T00:00:00Z", label = "mine"))
        assertEquals("theirs", Merge.merge(local, listOf(alarm(ID1, "2026-01-03T00:00:00Z", label = "theirs")))[ID1]!!.label)
        assertEquals("mine", Merge.merge(local, listOf(alarm(ID1, "2026-01-01T00:00:00Z", label = "theirs")))[ID1]!!.label)
    }

    @Test fun tieKeepsTheLocalRecord() {
        val local = map(alarm(ID1, "2026-01-02T00:00:00Z", label = "mine"))
        assertEquals("mine", Merge.merge(local, listOf(alarm(ID1, "2026-01-02T00:00:00Z", label = "theirs")))[ID1]!!.label)
    }

    @Test fun unknownRecordsAreAddedAndTombstonesWinWhenNewer() {
        val local = map(alarm(ID1, "2026-01-02T00:00:00Z"))
        val merged = Merge.merge(local, listOf(alarm(ID2, "2026-01-02T00:00:00Z"), alarm(ID1, "2026-01-05T00:00:00Z", deleted = "2026-01-05T00:00:00Z")))
        assertEquals(2, merged.size)
        assertTrue(merged[ID1]!!.isDeleted)
    }

    @Test fun anOlderTombstoneDoesNotKillANewerEdit() {
        val local = map(alarm(ID1, "2026-01-09T00:00:00Z", label = "revived"))
        assertFalse(Merge.merge(local, listOf(alarm(ID1, "2026-01-05T00:00:00Z", deleted = "2026-01-05T00:00:00Z")))[ID1]!!.isDeleted)
    }
}

class RecordSyncTest {
    private fun setup(mac: FakeMac, file: File? = null): Pair<SyncStore<AlarmRecord>, RecordSync<AlarmRecord>> {
        val store = SyncStore(file, AlarmCodec)
        return store to RecordSync(store, AlarmCodec, "alarm.sync", mac)
    }

    @Test fun pushesLocalEditsAndKeepsServerTimeAsSince() = runTest {
        val mac = FakeMac()
        val (store, sync) = setup(mac)
        store.put(alarm(ID1, "2026-11-13T09:00:00Z"))
        val r = sync.sync() as SyncResult.Synced
        assertEquals(1, r.pushed)
        assertEquals(1, mac.alarms.size)
        assertEquals(i("2026-11-13T10:00:00Z"), store.since)
        assertTrue(store.dirtyRecords().isEmpty())
        assertNull(mac.calls[0]["since"])
        sync.sync()
        assertEquals("2026-11-13T10:00:00Z", (mac.calls[1]["since"] as JsonPrimitive).content)
        assertEquals(0, mac.calls[1]["records"]!!.jsonArray.size)
    }

    @Test fun pullsTheMacsRecordsAndTombstones() = runTest {
        val mac = FakeMac()
        mac.alarms[ID2] = alarm(ID2, "2026-11-13T09:30:00Z", label = "from mac")
        val (store, sync) = setup(mac)
        sync.sync()
        assertEquals("from mac", store.live.value.single().label)
        mac.alarms[ID2] = alarm(ID2, "2026-11-13T11:00:00Z", deleted = "2026-11-13T11:00:00Z")
        sync.sync()
        assertTrue(store.live.value.isEmpty())
        assertNotNull(store.get(ID2)) // the tombstone is kept
    }

    @Test fun offlineEditsWaitAndArePushedAtReconnect() = runTest {
        val mac = FakeMac(connected = false)
        val (store, sync) = setup(mac)
        store.put(alarm(ID1, "2026-11-13T09:00:00Z"))
        assertEquals(SyncResult.Offline, sync.sync())
        assertEquals(1, store.dirtyRecords().size)
        assertTrue(mac.calls.isEmpty())
        mac.connected = true
        assertTrue(sync.sync() is SyncResult.Synced)
        assertEquals(1, mac.alarms.size)
        assertTrue(store.dirtyRecords().isEmpty())
    }

    @Test fun aFailedCallKeepsEditsForTheRetry() = runTest {
        val mac = FakeMac(); mac.failNext = 1
        val (store, sync) = setup(mac)
        store.put(alarm(ID1, "2026-11-13T09:00:00Z"))
        assertTrue(sync.sync() is SyncResult.Failed)
        assertEquals(1, store.dirtyRecords().size)
        assertNull(store.since)
        assertTrue(sync.sync() is SyncResult.Synced)
        assertTrue(store.dirtyRecords().isEmpty())
    }

    @Test fun anOlderMacWithoutTheToolKeepsLocalData() = runTest {
        val mac = FakeMac(tools = emptySet())
        val (store, sync) = setup(mac)
        store.put(alarm(ID1, "2026-11-13T09:00:00Z"))
        assertEquals(SyncResult.Unsupported, sync.sync())
        assertEquals(1, store.live.value.size)
        assertEquals(1, store.dirtyRecords().size)
    }

    @Test fun anEditMadeDuringTheCallStaysDirty() = runTest {
        val mac = FakeMac()
        val (store, _) = setup(mac)
        val first = alarm(ID1, "2026-11-13T09:00:00Z")
        store.put(first)
        val pushed = store.dirtyRecords()
        store.put(first.copy(label = "edited again", updatedAt = i("2026-11-13T09:00:05Z")))
        store.applySync(emptyList(), pushed, i("2026-11-13T10:00:00Z"))
        assertEquals(1, store.dirtyRecords().size)
    }

    @Test fun storePersistsRecordsDirtySetAndSince() {
        val f = File.createTempFile("alarms", ".json").apply { deleteOnExit() }
        val a = SyncStore(f, AlarmCodec)
        a.put(alarm(ID1, "2026-11-13T09:00:00Z", label = "kept"))
        a.applySync(emptyList(), emptyList(), i("2026-11-13T10:00:00Z"))
        val b = SyncStore(f, AlarmCodec)
        assertEquals("kept", b.live.value.single().label)
        assertEquals(i("2026-11-13T10:00:00Z"), b.since)
        assertEquals(1, b.dirtyRecords().size)
    }

    @Test fun notesSyncThroughTheSameClient() = runTest {
        var seen: JsonObject? = null
        val mac = object : MacCaller {
            override val isConnected = true
            override fun hasTool(name: String) = name == "note.sync"
            override suspend fun call(tool: String, input: JsonObject): JsonElement {
                seen = input
                return buildJsonObject { put("records", JsonArray(emptyList())); put("serverTime", "2026-11-13T10:00:00Z") }
            }
        }
        val store = SyncStore(null, NoteCodec)
        store.put(NoteRecord(ID2, "T", "body", listOf("a"), true, i("2026-11-13T09:00:00Z"), i("2026-11-13T09:00:00.700Z")))
        assertTrue(RecordSync(store, NoteCodec, "note.sync", mac).sync() is SyncResult.Synced)
        assertEquals("2026-11-13T09:00:00Z", (seen!!["records"]!!.jsonArray[0].jsonObject["updatedAt"] as JsonPrimitive).content)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SyncCoordinatorTest {
    @Test fun syncsOnConnectOnEditsOnMacChangesAndRetriesFailures() = runTest {
        val available = MutableStateFlow(false)
        val edits = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
        val changes = MutableSharedFlow<String>(extraBufferCapacity = 4)
        var runs = 0
        var failures = 1
        val results = mutableListOf<SyncResult>()
        SyncCoordinator(
            backgroundScope, listOf(SyncJob("alarms", edits) { runs++; if (failures > 0) { failures--; SyncResult.Failed("x") } else SyncResult.Synced(0, 0, 0) }),
            available, changes, retryMs = 1000, debounceMs = 100, quietMs = 500, nowMs = { testScheduler.currentTime },
            onResult = { _, r -> results += r },
        ).start()
        runCurrent()
        assertEquals(0, runs) // nothing before the Mac is available
        available.value = true
        runCurrent()
        assertEquals(1, runs); assertTrue(results.last() is SyncResult.Failed)
        advanceTimeBy(1001); runCurrent()
        assertEquals(2, runs); assertTrue(results.last() is SyncResult.Synced) // retried
        edits.tryEmit(Unit)
        advanceTimeBy(150); runCurrent()
        assertEquals(3, runs) // after the debounce
        advanceTimeBy(1000)
        changes.tryEmit("notes"); runCurrent()
        assertEquals(3, runs) // another topic
        changes.tryEmit("alarms"); runCurrent()
        assertEquals(4, runs)
        changes.tryEmit("alarms"); runCurrent()
        assertEquals(4, runs) // our own echo right after a sync is ignored
    }
}

class LinkErrorsTest {
    @Test fun epermMapsToTheLocalNetworkMessage() {
        val e = java.net.ConnectException("failed to connect to /10.0.2.2 (port 47800) from /:: (port 0) after 5000ms: connect failed: EPERM (Operation not permitted)")
        assertEquals("Allow apnum to find devices on your local network", LinkErrors.describe(e))
        assertEquals(LinkErrors.LOCAL_NETWORK, LinkErrors.describe(java.net.SocketException("Operation not permitted")))
        assertEquals(LinkErrors.LOCAL_NETWORK, LinkErrors.describe(SecurityException("x")))
    }

    @Test fun otherFailuresStayPlain() {
        assertTrue(LinkErrors.describe(java.net.ConnectException("Connection refused")).startsWith("Could not reach the Mac"))
        assertTrue(LinkErrors.describe(IllegalStateException("secret body")).let { !it.contains("secret") })
    }
}
