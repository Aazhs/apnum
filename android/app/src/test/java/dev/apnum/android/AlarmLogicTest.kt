package dev.apnum.android

import dev.apnum.android.alarm.AlarmLogic
import dev.apnum.android.sync.AlarmRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime

class AlarmLogicTest {
    private val utc = ZoneId.of("UTC")
    private val t0 = Instant.parse("2026-01-01T00:00:00Z")

    private fun alarm(h: Int, m: Int, days: List<String> = emptyList(), enabled: Boolean = true, id: String = "A") =
        AlarmRecord(id, h, m, "", days, enabled, 9, null, t0, t0)

    private fun at(s: String, zone: ZoneId = utc): Instant = ZonedDateTime.parse(s).withZoneSameInstant(zone).toInstant()

    @Test fun oneShotRingsTodayIfStillAhead() {
        assertEquals(Instant.parse("2026-11-13T07:30:00Z"), AlarmLogic.nextRing(alarm(7, 30), Instant.parse("2026-11-13T06:00:00Z"), utc))
    }

    @Test fun oneShotRingsTomorrowIfPassed() {
        assertEquals(Instant.parse("2026-11-14T07:30:00Z"), AlarmLogic.nextRing(alarm(7, 30), Instant.parse("2026-11-13T08:00:00Z"), utc))
    }

    @Test fun exactlyNowIsNotTheNextRing() {
        assertEquals(Instant.parse("2026-11-14T07:30:00Z"), AlarmLogic.nextRing(alarm(7, 30), Instant.parse("2026-11-13T07:30:00Z"), utc))
    }

    @Test fun repeatDaysPickTheNextChosenWeekday() {
        // 2026-11-13 is a Friday.
        val a = alarm(7, 0, listOf("monday", "wednesday"))
        assertEquals(Instant.parse("2026-11-16T07:00:00Z"), AlarmLogic.nextRing(a, Instant.parse("2026-11-13T12:00:00Z"), utc))
        assertEquals(Instant.parse("2026-11-18T07:00:00Z"), AlarmLogic.nextRing(a, Instant.parse("2026-11-16T07:00:00Z"), utc))
    }

    @Test fun repeatingTodayWhenStillAheadOnAChosenDay() {
        val a = alarm(18, 0, listOf("friday"))
        assertEquals(Instant.parse("2026-11-13T18:00:00Z"), AlarmLogic.nextRing(a, Instant.parse("2026-11-13T12:00:00Z"), utc))
        assertEquals(Instant.parse("2026-11-20T18:00:00Z"), AlarmLogic.nextRing(a, Instant.parse("2026-11-13T18:00:01Z"), utc))
    }

    @Test fun acrossMidnight() {
        val a = alarm(0, 15, listOf("saturday"))
        // Friday 23:50 -> Saturday 00:15 is 25 minutes away.
        assertEquals(Instant.parse("2026-11-14T00:15:00Z"), AlarmLogic.nextRing(a, Instant.parse("2026-11-13T23:50:00Z"), utc))
        // Sunday 23:59 with a Monday alarm at 00:05.
        assertEquals(Instant.parse("2026-11-16T00:05:00Z"), AlarmLogic.nextRing(alarm(0, 5, listOf("monday")), Instant.parse("2026-11-15T23:59:00Z"), utc))
    }

    @Test fun usesTheLocalZone() {
        val kolkata = ZoneId.of("Asia/Kolkata")
        // 07:00 IST is 01:30 UTC.
        assertEquals(Instant.parse("2026-11-14T01:30:00Z"), AlarmLogic.nextRing(alarm(7, 0), Instant.parse("2026-11-13T02:00:00Z"), kolkata))
    }

    @Test fun springForwardKeepsWallClockAndShiftsMissingTime() {
        val ny = ZoneId.of("America/New_York") // 2026-03-08: 02:00 -> 03:00
        val daily = alarm(7, 0, AlarmRecord.dayNames)
        val before = AlarmLogic.nextRing(daily, at("2026-03-07T06:00:00-05:00", ny), ny)!!
        val after = AlarmLogic.nextRing(daily, before, ny)!!
        assertEquals(7, before.atZone(ny).hour)
        assertEquals(7, after.atZone(ny).hour) // still 07:00 on the clock
        assertEquals(23L * 3600, after.epochSecond - before.epochSecond) // but a 23 hour day
        // 02:30 does not exist on 8 March: it rings at the first moment after the gap, not a day late.
        val gap = AlarmLogic.nextRing(alarm(2, 30), at("2026-03-08T00:00:00-05:00", ny), ny)!!
        assertEquals(3, gap.atZone(ny).hour)
        assertEquals(8, gap.atZone(ny).dayOfMonth)
    }

    @Test fun fallBackKeepsWallClock() {
        val ny = ZoneId.of("America/New_York") // 2026-11-01: 02:00 -> 01:00
        val daily = alarm(7, 0, AlarmRecord.dayNames)
        val before = AlarmLogic.nextRing(daily, at("2026-10-31T06:00:00-04:00", ny), ny)!!
        val after = AlarmLogic.nextRing(daily, before, ny)!!
        assertEquals(7, after.atZone(ny).hour)
        assertEquals(25L * 3600, after.epochSecond - before.epochSecond)
    }

    @Test fun disabledAndDeletedNeverRing() {
        assertNull(AlarmLogic.nextRing(alarm(7, 0, enabled = false), t0, utc))
        assertNull(AlarmLogic.nextRing(alarm(7, 0).copy(deletedAt = t0), t0, utc))
    }

    @Test fun planPicksTheSoonestIncludingSnoozes() {
        val a = alarm(9, 0, id = "A")
        val b = alarm(8, 0, id = "B")
        val now = Instant.parse("2026-11-13T06:00:00Z")
        assertEquals("B", AlarmLogic.plan(listOf(a, b), emptyMap(), now, utc)!!.alarmId)
        val snoozeAt = Instant.parse("2026-11-13T06:09:00Z")
        val p = AlarmLogic.plan(listOf(a, b.copy(isEnabled = false)), mapOf("B" to snoozeAt), now, utc)!!
        assertEquals("B", p.alarmId); assertEquals(snoozeAt, p.at); assertEquals(true, p.snooze)
        assertNull(AlarmLogic.plan(emptyList(), emptyMap(), now, utc))
    }

    @Test fun dueFindsWhatJustFell() {
        val a = alarm(7, 0, id = "A"); val b = alarm(7, 1, id = "B")
        val now = Instant.parse("2026-11-13T07:00:01Z")
        assertEquals(listOf("A"), AlarmLogic.due(listOf(a, b), emptyMap(), now, utc))
        // A snooze that has just expired is due too, even for a disabled one-shot.
        val s = Instant.parse("2026-11-13T07:00:00Z")
        assertEquals(listOf("C"), AlarmLogic.due(listOf(alarm(9, 0, enabled = false, id = "C")), mapOf("C" to s), now, utc))
        // Ten minutes later neither is due.
        assertEquals(emptyList<String>(), AlarmLogic.due(listOf(a, b), emptyMap(), now.plusSeconds(600), utc))
    }

    @Test fun repeatSummary() {
        assertEquals("Once", AlarmLogic.repeatSummary(alarm(1, 0)))
        assertEquals("Every day", AlarmLogic.repeatSummary(alarm(1, 0, AlarmRecord.dayNames)))
        assertEquals("Weekdays", AlarmLogic.repeatSummary(alarm(1, 0, AlarmRecord.dayNames.take(5))))
        assertEquals("Weekends", AlarmLogic.repeatSummary(alarm(1, 0, listOf("sunday", "saturday"))))
        assertEquals("Mon Fri", AlarmLogic.repeatSummary(alarm(1, 0, listOf("friday", "monday"))))
    }
}
