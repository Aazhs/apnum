package dev.apnum.android.link

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * One phone tool. [requires] lists the Android permissions (or pseudo-permissions such as
 * [Needs.NOTIFICATION_ACCESS]) that must be granted; the registry checks them before running the handler.
 */
class PhoneTool(
    val name: String,
    val summary: String,
    val tier: String,
    val inputSchema: JsonObject,
    val requires: List<String> = emptyList(),
    val handler: suspend (JsonObject) -> JsonElement,
) {
    val descriptor get() = ToolDescriptor(name, summary, tier, inputSchema)
}

object Needs {
    const val NOTIFICATION_ACCESS = "notification-access"
}

/** Tools the phone offers the Mac. [hasPermission] is injected so tests do not need Android. */
class ToolRegistry(private val hasPermission: (String) -> Boolean) {
    private val tools = linkedMapOf<String, PhoneTool>()

    fun register(vararg t: PhoneTool) = t.forEach { tools[it.name] = it }
    fun descriptors(): List<ToolDescriptor> = tools.values.map { it.descriptor }

    suspend fun call(name: String, input: JsonObject): JsonElement {
        val tool = tools[name] ?: throw ToolException(ErrorCode.NotFound, "The phone has no tool called $name.")
        val missing = tool.requires.firstOrNull { !hasPermission(it) }
        if (missing != null) throw unavailable("Permission needed on the phone: ${friendly(missing)}. Open apnum on the phone, Permissions, and grant it.")
        return tool.handler(input)
    }

    /** Runs a `call` message and builds the `result` reply. */
    suspend fun handleCall(m: JsonObject): JsonObject {
        val id = m.long("id") ?: return Messages.resultError(0, ErrorCode.InvalidInput, "call needs an id")
        val tool = m.str("tool") ?: return Messages.resultError(id, ErrorCode.InvalidInput, "call needs a tool")
        return try {
            Messages.resultOk(id, call(tool, m.obj("input") ?: JsonObject(emptyMap())))
        } catch (e: ToolException) {
            Messages.resultError(id, e.code, e.message ?: "failed")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SecurityException) {
            Messages.resultError(id, ErrorCode.Unavailable, "Android refused the request: ${e.message?.take(120)}")
        } catch (e: Exception) {
            // Never include input data in errors; the message of an unexpected exception is only its class and text.
            Messages.resultError(id, ErrorCode.Failed, e::class.java.simpleName)
        }
    }

    companion object {
        fun friendly(permission: String) = when (permission) {
            Needs.NOTIFICATION_ACCESS -> "Notification access"
            else -> permission.substringAfterLast('.')
        }
    }
}

/** JSON Schema helpers for tool inputs. */
object Schema {
    val empty: JsonObject = obj()

    fun obj(vararg props: Pair<String, JsonObject>, required: List<String> = emptyList()): JsonObject = buildJsonObject {
        put("type", "object")
        putJsonObject("properties") { props.forEach { (k, v) -> put(k, v) } }
        if (required.isNotEmpty()) putJsonArray("required") { required.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } }
        put("additionalProperties", false)
    }

    fun string(description: String) = buildJsonObject { put("type", "string"); put("description", description) }
    fun integer(description: String) = buildJsonObject { put("type", "integer"); put("description", description) }
    fun boolean(description: String) = buildJsonObject { put("type", "boolean"); put("description", description) }
}
