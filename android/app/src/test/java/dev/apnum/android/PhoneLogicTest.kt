package dev.apnum.android

import dev.apnum.android.phone.ActiveNotification
import dev.apnum.android.phone.CallEntry
import dev.apnum.android.phone.CallLogJson
import dev.apnum.android.phone.ClipboardGuard
import dev.apnum.android.phone.EventQueue
import dev.apnum.android.phone.NotificationClearer
import dev.apnum.android.phone.NotificationFilter
import dev.apnum.android.phone.NotificationSurface
import dev.apnum.android.phone.PhoneNumber
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneLogicTest {
    @Test fun numberFormattingIsStripped() {
        assertEquals("+919876543210", PhoneNumber.normalize("+91 98765-43210"))
        assertEquals("5551234", PhoneNumber.normalize("(555) 1234"))
        assertEquals("+14155550100", PhoneNumber.normalize(" +1 (415) 555.0100 "))
        assertEquals("56161", PhoneNumber.normalize("56161"))
    }

    @Test fun nonDialableAddressesAreRejected() {
        assertNull(PhoneNumber.normalize("JD-GROWWO-S"))
        assertNull(PhoneNumber.normalize("AX-HDFCBK"))
        assertNull(PhoneNumber.normalize(""))
        assertNull(PhoneNumber.normalize(null))
        assertNull(PhoneNumber.normalize("12"))
        assertNull(PhoneNumber.normalize("1234567890123456"))
        assertNull(PhoneNumber.normalize("98+7654321"))
        assertNull(PhoneNumber.normalize("98765 4321x"))
    }

    @Test fun queueKeepsLastTwentyAndDropsOldOnes() {
        var now = 0L
        val q = EventQueue(clock = { now })
        repeat(25) { q.add("sms.received", buildJsonObject { put("n", it) }) }
        assertEquals(20, q.size)
        val out = q.drain()
        assertEquals(20, out.size)
        assertEquals(5, out.first().data["n"]!!.jsonPrimitive.content.toInt())
        assertEquals(0, q.size)

        q.add("a", JsonObject(emptyMap()))
        now += 5 * 60_000
        q.add("b", JsonObject(emptyMap()))
        now += 6 * 60_000 // "a" is now 11 minutes old, "b" 6
        assertEquals(listOf("b"), q.drain().map { it.topic })
    }

    @Test fun clipboardIsNotEchoedBack() {
        val g = ClipboardGuard()
        g.receivedFromPeer("from mac")
        assertFalse(g.shouldSend("from mac")) // the listener fires for our own setPrimaryClip
        assertTrue(g.shouldSend("typed on phone"))
        assertFalse(g.shouldSend("typed on phone")) // unchanged on resume
        assertTrue(g.shouldSend("from mac")) // a genuine re-copy after the user copied something else... is only blocked while it is the last peer text
    }

    @Test fun clipboardGuardRefusesEmptyAndHuge() {
        val g = ClipboardGuard()
        assertFalse(g.shouldSend(null))
        assertFalse(g.shouldSend(""))
        assertFalse(g.shouldSend("x".repeat(ClipboardGuard.MAX_CHARS + 1)))
        assertTrue(g.shouldSend("x".repeat(ClipboardGuard.MAX_CHARS)))
    }

    @Test fun clearDismissesOnlyClearableForeignNotifications() {
        val cancelled = mutableListOf<String>()
        val surface = object : NotificationSurface {
            override fun active() = listOf(
                ActiveNotification("a", ownPackage = false, clearable = true),
                ActiveNotification("b", ownPackage = false, clearable = false), // ongoing, e.g. music
                ActiveNotification("c", ownPackage = true, clearable = true), // apnum's own
                ActiveNotification("d", ownPackage = false, clearable = true),
            )
            override fun cancel(key: String) { cancelled += key }
        }
        assertEquals(2, NotificationClearer.clear(surface))
        assertEquals(listOf("a", "d"), cancelled)
    }

    @Test fun mirroringSkipsOwnOngoingAndSummaries() {
        assertTrue(NotificationFilter.mirror(ownPackage = false, ongoing = false, groupSummary = false))
        assertFalse(NotificationFilter.mirror(ownPackage = true, ongoing = false, groupSummary = false))
        assertFalse(NotificationFilter.mirror(ownPackage = false, ongoing = true, groupSummary = false))
        assertFalse(NotificationFilter.mirror(ownPackage = false, ongoing = false, groupSummary = true))
    }

    @Test fun callLogShape() {
        assertEquals("incoming", CallLogJson.typeName(1))
        assertEquals("outgoing", CallLogJson.typeName(2))
        assertEquals("missed", CallLogJson.typeName(3))
        assertEquals("missed", CallLogJson.typeName(5))
        val json = CallLogJson.toJson(listOf(CallEntry("+911234567890", null, "missed", 1_700_000_000_000, 0), CallEntry("555", "Mum", "incoming", 1_700_000_100_000, 62)))
        val calls: JsonArray = json["calls"]!!.jsonArray
        assertEquals(2, calls.size)
        assertEquals("missed", calls[0].jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("Mum", calls[1].jsonObject["contactName"]!!.jsonPrimitive.content)
        assertEquals("62", calls[1].jsonObject["durationSec"]!!.jsonPrimitive.content)
    }
}
