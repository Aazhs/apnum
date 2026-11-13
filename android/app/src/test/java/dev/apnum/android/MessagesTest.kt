package dev.apnum.android

import dev.apnum.android.link.DeviceInfo
import dev.apnum.android.link.ErrorCode
import dev.apnum.android.link.Messages
import dev.apnum.android.link.Schema
import dev.apnum.android.link.ToolDescriptor
import dev.apnum.android.link.ToolException
import dev.apnum.android.link.bool
import dev.apnum.android.link.long
import dev.apnum.android.link.str
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class MessagesTest {
    private val device = DeviceInfo("id-1", "moto g86 power", "android", "0.1.0", "Android 16")

    @Test fun encodeDecodeRoundTrip() {
        val m = Messages.event("battery", buildJsonObject { put("percent", 85); put("charging", true) })
        val back = Messages.decode(Messages.encode(m))!!
        assertEquals("event", Messages.type(back))
        assertEquals("battery", back.str("topic"))
        assertEquals(true, (back["data"] as kotlinx.serialization.json.JsonObject).bool("charging"))
    }

    @Test fun decodeRejectsGarbage() {
        assertNull(Messages.decode("not json".toByteArray()))
        assertNull(Messages.decode("[1,2]".toByteArray()))
    }

    @Test fun helloCarriesDeviceAndTools() {
        val tool = ToolDescriptor("phone.info", "Info", "read", Schema.empty)
        val m = Messages.hello(device, listOf(tool))
        assertEquals("hello", m.str("t"))
        assertEquals(1L, m.long("v"))
        assertEquals("android", (m["device"] as kotlinx.serialization.json.JsonObject).str("kind"))
        val tools = ToolDescriptor.listFromJson(m["tools"])
        assertEquals(listOf("phone.info"), tools.map { it.name })
        assertEquals("read", tools[0].tier)
    }

    @Test fun pairMessageUsesTokenAndDevice() {
        val m = Messages.pair("12345678", device)
        assertEquals("pair", m.str("t"))
        assertEquals("12345678", m.str("token"))
        assertEquals("moto g86 power", DeviceInfo.fromJson(m["device"] as kotlinx.serialization.json.JsonObject)?.name)
    }

    @Test fun callIdIsANumber() {
        val m = Messages.call(7, "mac.lock", buildJsonObject {})
        assertEquals(7L, m.long("id"))
        assertTrue(m["id"] is JsonPrimitive && !(m["id"] as JsonPrimitive).isString)
    }

    @Test fun unknownFieldsAreIgnored() {
        val m = Messages.decode("""{"t":"result","id":3,"ok":true,"output":{"a":1},"extra":"x"}""".toByteArray())!!
        assertEquals("""{"a":1}""", Messages.unwrapResult(m).toString())
    }

    @Test fun resultErrorSurfacesTheMacMessage() {
        val m = Messages.decode(Messages.encode(Messages.resultError(5, ErrorCode.Denied, "Dangerous actions are off.")))!!
        try {
            Messages.unwrapResult(m)
            fail("expected an error")
        } catch (e: ToolException) {
            assertEquals(ErrorCode.Denied, e.code)
            assertEquals("Dangerous actions are off.", e.message)
        }
    }
}
