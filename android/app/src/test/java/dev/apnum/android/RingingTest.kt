package dev.apnum.android

import dev.apnum.android.alarm.AlarmController
import dev.apnum.android.alarm.AlarmRepository
import dev.apnum.android.alarm.MacRingingItem
import dev.apnum.android.alarm.RingEnvironment
import dev.apnum.android.alarm.Ringing
import dev.apnum.android.alarm.RingingCoordinator
import dev.apnum.android.notes.NoteRepository
import dev.apnum.android.sync.AlarmCodec
import dev.apnum.android.sync.NoteCodec
import dev.apnum.android.sync.SyncStore
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.Instant

class RingingCoordinatorTest {
    @Test fun stopsOnlyWhatTheMacHadListed() {
        val c = RingingCoordinator()
        c.localStarted("A")
        assertEquals(emptySet<String>(), c.onMacRinging(emptySet())) // never listed: keep ringing alone
        assertEquals(emptySet<String>(), c.onMacRinging(setOf("A")))
        assertEquals(setOf("A"), c.onMacRinging(emptySet())) // listed, now gone: stop
        assertEquals(emptySet<String>(), c.localIds())
    }

    @Test fun idsCompareCaseInsensitively() {
        val c = RingingCoordinator()
        c.localStarted("AB-CD")
        c.onMacRinging(setOf("ab-cd"))
        assertEquals(setOf("AB-CD"), c.onMacRinging(emptySet()))
    }

    @Test fun otherAlarmsAreUntouched() {
        val c = RingingCoordinator()
        c.localStarted("A"); c.localStarted("B")
        c.onMacRinging(setOf("A", "B"))
        assertEquals(setOf("A"), c.onMacRinging(setOf("B")))
        assertEquals(setOf("B"), c.localIds())
    }
}

private class FakeEnv : RingEnvironment {
    val macCalls = mutableListOf<Pair<String, String>>()
    val events = mutableListOf<Pair<String, JsonObject>>()
    var services = 0; var reschedules = 0
    var timers = listOf<MacRingingItem>()
    var missed = listOf<Ringing>()
    override suspend fun callMac(tool: String, input: JsonObject) { macCalls += tool to input["id"].toString().trim('"') }
    override fun sendEvent(topic: String, data: JsonObject) { events += topic to data }
    override fun ensureServiceRunning() { services++ }
    override fun rescheduleAlarms() { reschedules++ }
    override fun showTimers(items: List<MacRingingItem>) { timers = items }
    override fun showMissed(r: Ringing) { missed = missed + r }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AlarmControllerTest {
    private val now = Instant.parse("2026-11-13T07:00:00Z")

    private fun repo() = AlarmRepository(SyncStore(null, AlarmCodec), null, { now })

    @Test fun ringingCoordinatesWithTheMac() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "Gym", emptySet(), 5)
        val c = AlarmController(repo, env, backgroundScope)
        c.ring(a.id)
        assertEquals(listOf(Ringing(a.id, "Gym", 7, 0)), c.ringing.value)
        assertEquals(1, env.services)
        assertEquals(listOf(a.id), env.events.last().second["ids"]!!.jsonArray.map { it.toString().trim('"') })
        // Starting to ring changes nothing that syncs.
        assertTrue(repo.get(a.id)!!.isEnabled)
        // The Mac lists it, then no longer: the phone stops, without calling the Mac back.
        c.onMacRinging(MacRingingItem.parse(Json.parseToJsonElement("""{"items":[{"id":"${a.id.lowercase()}","kind":"alarm","title":"Gym","body":"","canSnooze":true}]}""").jsonObject))
        assertEquals(1, c.ringing.value.size)
        c.onMacRinging(emptyList())
        assertTrue(c.ringing.value.isEmpty())
        runCurrent()
        assertTrue(env.macCalls.isEmpty())
        assertFalse(repo.get(a.id)!!.isEnabled) // the ring ended on the Mac, so the one-shot is off here too
    }

    @Test fun ringStartLeavesTheRecordIdenticalAndQueuesNothing() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "Gym", emptySet(), 5)
        val before = AlarmCodec.toJson(repo.get(a.id)!!).toString()
        val dirtyBefore = repo.store.dirtyRecords().map { it.id to it.updatedAt }
        val c = AlarmController(repo, env, backgroundScope)
        c.ring(a.id)
        assertEquals(before, AlarmCodec.toJson(repo.get(a.id)!!).toString())
        assertEquals(dirtyBefore, repo.store.dirtyRecords().map { it.id to it.updatedAt })
    }

    @Test fun stoppingDisablesAOneShotAndSnoozeKeepsItOn() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "", emptySet(), 5)
        val b = repo.create(7, 0, "", emptySet(), 5)
        val c = AlarmController(repo, env, backgroundScope)
        c.ring(a.id); c.ring(b.id)
        c.snooze(a.id)
        assertTrue(repo.get(a.id)!!.isEnabled)
        c.stop(b.id)
        assertFalse(repo.get(b.id)!!.isEnabled)
    }

    @Test fun timeoutDisablesAOneShot() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "", emptySet(), 5)
        val c = AlarmController(repo, env, backgroundScope)
        c.ring(a.id)
        advanceTimeBy(10 * 60_000L + 1_000L); runCurrent()
        assertFalse(repo.get(a.id)!!.isEnabled)
    }

    @Test fun aWakeInsideTheWindowDoesNotRingTwice() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "", setOf(DayOfWeek.FRIDAY), 5) // 2026-11-13 is a Friday
        val c = AlarmController(repo, env, backgroundScope)
        c.ringDue(now.plusSeconds(1), java.time.ZoneId.of("UTC"))
        c.stop(a.id)
        c.ringDue(now.plusSeconds(5), java.time.ZoneId.of("UTC"))
        assertTrue(c.ringing.value.isEmpty())
        assertTrue(repo.get(a.id)!!.isEnabled) // repeating alarms stay enabled
    }

    @Test fun stopAndSnoozeOnThePhoneTellTheMac() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "", setOf(DayOfWeek.MONDAY), 5)
        val b = repo.create(7, 0, "", emptySet(), 5)
        val c = AlarmController(repo, env, backgroundScope)
        c.ring(a.id); c.ring(b.id)
        c.snooze(a.id)
        c.stop(b.id)
        runCurrent()
        assertEquals(listOf("alarm.snooze" to a.id, "alarm.stop" to b.id), env.macCalls)
        assertEquals(now.plusSeconds(300), repo.snoozedUntil()[a.id])
        assertTrue(c.ringing.value.isEmpty())
        assertTrue(repo.get(a.id)!!.isEnabled) // a repeating alarm stays on
    }

    @Test fun anAlarmTheMacNeverListedKeepsRinging() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "", emptySet(), 5)
        val c = AlarmController(repo, env, backgroundScope)
        c.ring(a.id)
        c.onMacRinging(emptyList())
        assertEquals(1, c.ringing.value.size)
    }

    @Test fun autoStopsAfterTenMinutesAndRecordsAMiss() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "x", emptySet(), 5)
        val c = AlarmController(repo, env, backgroundScope)
        c.ring(a.id)
        advanceTimeBy(9 * 60_000L); runCurrent()
        assertEquals(1, c.ringing.value.size)
        advanceTimeBy(61_000L); runCurrent()
        assertTrue(c.ringing.value.isEmpty())
        assertEquals(1, env.missed.size)
        assertEquals("alarm.stop", env.macCalls.single().first)
    }

    @Test fun timersInTheMacsEventGetANotification() = runTest {
        val env = FakeEnv()
        val c = AlarmController(repo(), env, backgroundScope)
        c.onMacRinging(listOf(MacRingingItem("T1", "timer", "Tea", "Done", false)))
        assertEquals("T1", env.timers.single().id)
        c.onMacRinging(emptyList())
        assertTrue(env.timers.isEmpty())
    }

    @Test fun ringDueRingsWhatFellDue() = runTest {
        val repo = repo(); val env = FakeEnv()
        val a = repo.create(7, 0, "", emptySet(), 5)
        repo.create(9, 0, "", emptySet(), 5)
        val c = AlarmController(repo, env, backgroundScope)
        c.ringDue(now.plusSeconds(1), java.time.ZoneId.of("UTC"))
        assertEquals(listOf(a.id), c.ringing.value.map { it.id })
    }

    @Test fun deletingLeavesATombstone() {
        val repo = repo()
        val a = repo.create(7, 0, "", emptySet(), 5)
        repo.delete(a.id)
        assertNull(repo.get(a.id))
        assertTrue(repo.store.get(a.id)!!.isDeleted)
        assertTrue(repo.store.dirtyRecords().single().isDeleted)
    }
}

class NoteRepositoryTest {
    private var t = Instant.parse("2026-11-13T07:00:00Z")
    private fun repo() = NoteRepository(SyncStore(null, NoteCodec)) { t = t.plusSeconds(10); t }

    @Test fun emptyNewNotesLeaveNothingAndEditsStick() {
        val r = repo(); val id = r.newId()
        assertFalse(r.save(id, "", "  ", emptyList(), false))
        assertTrue(r.store.all().isEmpty())
        assertTrue(r.save(id, "Plan", "# Plan", listOf("#work", " work ", ""), false))
        assertEquals(listOf("work"), r.get(id)!!.tags)
        val first = r.get(id)!!.updatedAt
        r.save(id, "Plan", "# Plan", listOf("work"), false) // unchanged: no new version
        assertEquals(first, r.get(id)!!.updatedAt)
        r.save(id, "Plan", "# Plan\n- one", listOf("work"), true)
        assertTrue(r.get(id)!!.pinned)
    }

    @Test fun deletedNotesStayDeletedEvenIfTheEditorSavesAgain() {
        val r = repo(); val id = r.newId()
        r.save(id, "x", "y", emptyList(), false)
        r.delete(id)
        assertNull(r.get(id))
        assertFalse(r.save(id, "x", "y", emptyList(), false))
        assertTrue(r.store.get(id)!!.isDeleted)
    }

    @Test fun pinnedFirstThenNewestAndSearchAndTags() {
        val r = repo()
        val a = r.newId(); r.save(a, "Alpha", "café plans", listOf("home"), false)
        val b = r.newId(); r.save(b, "Beta", "second", listOf("work"), true)
        val c = r.newId(); r.save(c, "Gamma", "third", listOf("home"), false)
        val all = r.store.live.value
        assertEquals(listOf("Beta", "Gamma", "Alpha"), NoteRepository.filter(all, "", null).map { it.title })
        assertEquals(listOf("Alpha"), NoteRepository.filter(all, "CAFE", null).map { it.title })
        assertEquals(listOf("Gamma", "Alpha"), NoteRepository.filter(all, "", "home").map { it.title })
        assertEquals(listOf("home", "work"), NoteRepository.allTags(all))
    }
}
