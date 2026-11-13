package dev.apnum.android

import dev.apnum.android.link.ErrorCode
import dev.apnum.android.link.Messages
import dev.apnum.android.link.Needs
import dev.apnum.android.link.PhoneTool
import dev.apnum.android.link.Schema
import dev.apnum.android.link.ToolException
import dev.apnum.android.link.ToolRegistry
import dev.apnum.android.link.bool
import dev.apnum.android.link.long
import dev.apnum.android.link.obj
import dev.apnum.android.link.str
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolRegistryTest {
    private val granted = mutableSetOf<String>()
    private val registry = ToolRegistry { it in granted }.apply {
        register(
            PhoneTool("phone.echo", "Echo", "read", Schema.obj("text" to Schema.string("t"))) { buildJsonObject { put("text", (it.str("text") ?: "")) } },
            PhoneTool("phone.sms.list", "SMS", "read", Schema.empty, listOf("android.permission.READ_SMS")) { buildJsonObject { put("n", 0) } },
            PhoneTool("phone.notifications.list", "N", "read", Schema.empty, listOf(Needs.NOTIFICATION_ACCESS)) { buildJsonObject {} },
            PhoneTool("phone.boom", "Boom", "write", Schema.empty) { throw IllegalStateException("secret body text") },
            PhoneTool("phone.bad", "Bad", "write", Schema.empty) { throw ToolException(ErrorCode.InvalidInput, "to must be a phone number.") },
        )
    }

    private fun call(id: Long, tool: String, input: JsonObject = buildJsonObject {}) =
        runBlocking { registry.handleCall(Messages.call(id, tool, input)) }

    @Test fun dispatchReturnsOutputWithMatchingId() {
        val r = call(11, "phone.echo", buildJsonObject { put("text", "hi") })
        assertEquals("result", r.str("t"))
        assertEquals(11L, r.long("id"))
        assertTrue(r.bool("ok")!!)
        assertEquals("hi", r.obj("output")!!.str("text"))
    }

    @Test fun unknownToolIsNotFound() {
        val r = call(1, "phone.nope")
        assertFalse(r.bool("ok")!!)
        assertEquals("notFound", r.obj("error")!!.str("code"))
    }

    @Test fun missingRuntimePermissionIsUnavailableAndNamesIt() {
        val r = call(2, "phone.sms.list")
        assertFalse(r.bool("ok")!!)
        val e = r.obj("error")!!
        assertEquals("unavailable", e.str("code"))
        assertTrue(e.str("message")!!.contains("READ_SMS"))
    }

    @Test fun grantedPermissionRuns() {
        granted += "android.permission.READ_SMS"
        assertTrue(call(3, "phone.sms.list").bool("ok")!!)
    }

    @Test fun notificationAccessIsNamedInPlainWords() {
        val r = call(4, "phone.notifications.list")
        assertTrue(r.obj("error")!!.str("message")!!.contains("Notification access"))
    }

    @Test fun toolErrorsKeepTheirCode() {
        assertEquals("invalidInput", call(5, "phone.bad").obj("error")!!.str("code"))
    }

    @Test fun unexpectedExceptionsDoNotLeakTheirMessage() {
        val r = call(6, "phone.boom")
        val e = r.obj("error")!!
        assertEquals("failed", e.str("code"))
        assertFalse(e.str("message")!!.contains("secret"))
    }

    @Test fun descriptorsListEveryToolEvenWithoutPermission() {
        assertEquals(5, registry.descriptors().size)
        assertEquals("phone.echo", registry.descriptors().first().name)
    }
}
