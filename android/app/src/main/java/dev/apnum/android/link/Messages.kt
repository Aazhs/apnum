package dev.apnum.android.link

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

const val PROTOCOL_VERSION = 1

val linkJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

/** `device` in `pair`, `paired` and `hello`. */
data class DeviceInfo(val id: String, val name: String, val kind: String, val app: String, val os: String) {
    fun toJson(): JsonObject = buildJsonObject {
        put("id", id); put("name", name); put("kind", kind); put("app", app); put("os", os)
    }

    companion object {
        fun fromJson(o: JsonObject?): DeviceInfo? {
            o ?: return null
            val id = o.str("id") ?: return null
            return DeviceInfo(id, o.str("name") ?: "Mac", o.str("kind") ?: "mac", o.str("app") ?: "", o.str("os") ?: "")
        }
    }
}

/** Same shape as `ToolDescriptor` in ApnumCore. */
data class ToolDescriptor(val name: String, val summary: String, val tier: String, val inputSchema: JsonObject) {
    fun toJson(): JsonObject = buildJsonObject {
        put("name", name); put("summary", summary); put("tier", tier); put("inputSchema", inputSchema)
    }

    companion object {
        fun fromJson(o: JsonObject): ToolDescriptor? {
            val name = o.str("name") ?: return null
            return ToolDescriptor(
                name, o.str("summary") ?: "", o.str("tier") ?: "read",
                (o["inputSchema"] as? JsonObject) ?: JsonObject(emptyMap()),
            )
        }

        fun listFromJson(e: JsonElement?): List<ToolDescriptor> =
            (e as? kotlinx.serialization.json.JsonArray)?.mapNotNull { (it as? JsonObject)?.let(::fromJson) } ?: emptyList()
    }
}

/** Error codes from the spec (the cases of `ToolError`). */
enum class ErrorCode(val wire: String) { NotFound("notFound"), InvalidInput("invalidInput"), Denied("denied"), Unavailable("unavailable"), Failed("failed") }

class ToolException(val code: ErrorCode, message: String) : Exception(message)

fun unavailable(message: String) = ToolException(ErrorCode.Unavailable, message)
fun invalidInput(message: String) = ToolException(ErrorCode.InvalidInput, message)

/** Builders and parsers for the sealed-message plaintext (one UTF-8 JSON object with a `t` field). */
object Messages {
    fun encode(o: JsonObject): ByteArray = linkJson.encodeToString(JsonObject.serializer(), o).toByteArray(Charsets.UTF_8)

    fun decode(bytes: ByteArray): JsonObject? = try {
        linkJson.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
    } catch (_: Exception) {
        null
    }

    fun type(m: JsonObject): String? = m.str("t")

    fun pair(token: String, device: DeviceInfo) = buildJsonObject { put("t", "pair"); put("token", token); put("device", device.toJson()) }

    fun hello(device: DeviceInfo, tools: List<ToolDescriptor>) = buildJsonObject {
        put("t", "hello"); put("v", PROTOCOL_VERSION); put("device", device.toJson())
        putJsonArray("tools") { tools.forEach { add(it.toJson()) } }
    }

    fun tools(tools: List<ToolDescriptor>) = buildJsonObject {
        put("t", "tools")
        putJsonArray("tools") { tools.forEach { add(it.toJson()) } }
    }

    fun call(id: Long, tool: String, input: JsonObject) = buildJsonObject { put("t", "call"); put("id", id); put("tool", tool); put("input", input) }

    fun resultOk(id: Long, output: JsonElement) = buildJsonObject { put("t", "result"); put("id", id); put("ok", true); put("output", output) }

    fun resultError(id: Long, code: ErrorCode, message: String) = buildJsonObject {
        put("t", "result"); put("id", id); put("ok", false)
        put("error", buildJsonObject { put("code", code.wire); put("message", message) })
    }

    fun event(topic: String, data: JsonObject) = buildJsonObject { put("t", "event"); put("topic", topic); put("data", data) }
    fun ping() = buildJsonObject { put("t", "ping") }
    fun pong() = buildJsonObject { put("t", "pong") }
    fun bye(reason: String) = buildJsonObject { put("t", "bye"); put("reason", reason) }

    /** Reads a `result` into its output, or throws the Mac's error as a [ToolException]. */
    fun unwrapResult(m: JsonObject): JsonElement {
        if (m.bool("ok") == true) return m["output"] ?: JsonNull
        val err = m["error"] as? JsonObject
        val code = ErrorCode.entries.firstOrNull { it.wire == err?.str("code") } ?: ErrorCode.Failed
        throw ToolException(code, err?.str("message") ?: "The Mac reported an error.")
    }
}

fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }
fun JsonObject.int(key: String): Int? = long(key)?.toInt()
fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
