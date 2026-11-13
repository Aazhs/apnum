package dev.apnum.android.phone

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Pure logic behind the phone tools, kept free of Android types so it can be unit tested. */
object PhoneNumber {
    /**
     * Strips spaces, dashes, dots and brackets and keeps a leading `+`. Returns null when the result is not dialable
     * (an alphanumeric sender such as `JD-GROWWO-S`, or too short or long to be a number).
     */
    fun normalize(raw: String?): String? {
        val s = raw?.trim().orEmpty()
        if (s.isEmpty()) return null
        if (!s.all { it.isDigit() || it in "+ -(). " }) return null
        val plus = s.startsWith("+")
        if (s.drop(if (plus) 1 else 0).contains('+')) return null
        val digits = s.filter { it.isDigit() }
        if (digits.length !in 3..15) return null
        return (if (plus) "+" else "") + digits
    }
}

/** Events that could not be sent because the link was down: kept for [maxAgeMs], at most [max], oldest dropped first. */
class EventQueue(
    private val max: Int = 20,
    private val maxAgeMs: Long = 10 * 60_000L,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    class Item(val topic: String, val data: JsonObject, val atMs: Long)

    private val items = ArrayDeque<Item>()

    @Synchronized
    fun add(topic: String, data: JsonObject) {
        items.addLast(Item(topic, data, clock()))
        while (items.size > max) items.removeFirst()
    }

    /** Removes and returns everything still fresh, oldest first. */
    @Synchronized
    fun drain(): List<Item> {
        val cutoff = clock() - maxAgeMs
        val fresh = items.filter { it.atMs >= cutoff }
        items.clear()
        return fresh
    }

    val size: Int @Synchronized get() = items.size
}

/** Stops clipboard text that came from the Mac from being sent straight back, and repeats of the same text. */
class ClipboardGuard {
    private var lastFromPeer: String? = null
    private var lastSent: String? = null

    @Synchronized fun receivedFromPeer(text: String) { lastFromPeer = text; lastSent = null }

    /** True when [text] should go to the Mac now; records it as sent. */
    @Synchronized
    fun shouldSend(text: String?): Boolean {
        if (text.isNullOrEmpty() || text.length > MAX_CHARS) return false
        if (text == lastFromPeer || text == lastSent) return false
        lastSent = text
        lastFromPeer = null // a different text was copied here, so the Mac's text may be copied again later
        return true
    }

    companion object { const val MAX_CHARS = 100_000 }
}

data class CallEntry(val number: String?, val contactName: String?, val type: String, val dateMs: Long, val durationSec: Long)

object CallLogJson {
    /** Maps `CallLog.Calls.TYPE` values (1 incoming, 2 outgoing; missed, rejected and blocked all count as missed). */
    fun typeName(type: Int): String = when (type) {
        1 -> "incoming"
        2 -> "outgoing"
        else -> "missed"
    }

    fun toJson(entries: List<CallEntry>): JsonObject = buildJsonObject {
        put("calls", buildJsonArray {
            entries.forEach {
                add(buildJsonObject {
                    put("number", it.number); put("contactName", it.contactName); put("type", it.type)
                    put("dateMs", it.dateMs); put("durationSec", it.durationSec)
                })
            }
        })
    }
}

/** One active notification as far as clearing is concerned. */
data class ActiveNotification(val key: String, val ownPackage: Boolean, val clearable: Boolean)

interface NotificationSurface {
    fun active(): List<ActiveNotification>
    fun cancel(key: String)
}

object NotificationClearer {
    /** Dismisses every clearable notification that is not apnum's own; returns how many. */
    fun clear(surface: NotificationSurface): Int {
        val targets = surface.active().filter { it.clearable && !it.ownPackage }
        targets.forEach { surface.cancel(it.key) }
        return targets.size
    }
}

/** Which notifications are worth telling the Mac about. */
object NotificationFilter {
    fun mirror(ownPackage: Boolean, ongoing: Boolean, groupSummary: Boolean): Boolean = !ownPackage && !ongoing && !groupSummary
}
