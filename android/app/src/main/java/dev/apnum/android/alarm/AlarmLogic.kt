package dev.apnum.android.alarm

import dev.apnum.android.sync.AlarmRecord
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** When an alarm rings next, and which alarm the phone should wake up for. Pure java.time, no Android. */
object AlarmLogic {
    /**
     * The first ring strictly after [after] at the alarm's wall-clock time in [zone]: today or tomorrow for a
     * one-time alarm, the next chosen weekday for a repeating one. Built from local dates, so a daylight
     * saving change never moves the wall-clock time (a time that does not exist that day rings at the first
     * moment that does).
     */
    fun nextRing(alarm: AlarmRecord, after: Instant, zone: ZoneId): Instant? {
        if (!alarm.isEnabled || alarm.isDeleted) return null
        val start = after.atZone(zone).toLocalDate()
        val days = alarm.days
        val time = LocalTime.of(alarm.hour, alarm.minute)
        for (offset in 0L..8L) {
            val date = start.plusDays(offset)
            if (days.isNotEmpty() && date.dayOfWeek !in days) continue
            val candidate = ZonedDateTime.of(date, time, zone).toInstant()
            if (candidate.isAfter(after)) return candidate
        }
        return null
    }

    class Plan(val alarmId: String, val at: Instant, val snooze: Boolean)

    /** The soonest wake-up across all alarms and snoozes (snoozedUntil per alarm id). */
    fun plan(alarms: List<AlarmRecord>, snoozedUntil: Map<String, Instant>, after: Instant, zone: ZoneId): Plan? {
        var best: Plan? = null
        for (a in alarms) {
            if (a.isDeleted) continue
            val snooze = snoozedUntil[a.id]?.takeIf { it.isAfter(after) }
            val next = nextRing(a, after, zone)
            val options = listOfNotNull(next?.let { Plan(a.id, it, false) }, snooze?.let { Plan(a.id, it, true) })
            for (o in options) if (best == null || o.at.isBefore(best.at)) best = o
        }
        return best
    }

    /** Alarms (and snoozes) whose time fell in the last [windowSec] seconds up to [now]: what a wake-up should ring. */
    fun due(alarms: List<AlarmRecord>, snoozedUntil: Map<String, Instant>, now: Instant, zone: ZoneId, windowSec: Long = 30): List<String> {
        val from = now.minusSeconds(windowSec)
        val out = LinkedHashSet<String>()
        val horizon = now.plusSeconds(2)
        for (a in alarms) {
            if (a.isDeleted) continue
            val ring = nextRing(a, from, zone)
            if (ring != null && !ring.isAfter(horizon)) out += a.id
            val s = snoozedUntil[a.id]
            if (s != null && s.isAfter(from) && !s.isAfter(horizon)) out += a.id
        }
        return out.toList()
    }

    /** "Mon Tue Wed","Every day", "Weekdays", "Weekends" or "Once". */
    fun repeatSummary(alarm: AlarmRecord): String {
        val d = alarm.days
        val names = listOf("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
        val picked = names.filter { n -> d.any { it.name.equals(n, true) } }
        return when {
            picked.isEmpty() -> "Once"
            picked.size == 7 -> "Every day"
            picked == names.take(5) -> "Weekdays"
            picked == names.drop(5) -> "Weekends"
            else -> picked.joinToString(" ") { it.take(3).replaceFirstChar(Char::uppercase) }
        }
    }
}

/**
 * Keeps the phone and the Mac quiet together. [onMacRinging] takes the alarm ids in the Mac's `ringing` event
 * and returns the local alarms to stop: those the Mac listed at some point while they rang here and no longer
 * lists. An alarm the Mac never listed (offline when it started, or an older Mac) rings on its own.
 */
class RingingCoordinator {
    private val local = LinkedHashSet<String>()
    private val seenOnMac = HashSet<String>()

    @Synchronized fun localStarted(id: String) { local += id }
    @Synchronized fun localEnded(id: String) { local -= id; seenOnMac -= id }
    @Synchronized fun localIds(): Set<String> = local.toSet()

    @Synchronized fun onMacRinging(macAlarmIds: Set<String>): Set<String> {
        val upper = macAlarmIds.map { it.uppercase() }.toSet()
        for (id in local) if (id in upper) seenOnMac += id
        val stop = local.filter { it in seenOnMac && it !in upper }.toSet()
        stop.forEach { local -= it; seenOnMac -= it }
        return stop
    }
}
