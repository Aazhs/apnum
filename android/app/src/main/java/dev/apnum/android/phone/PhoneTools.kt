package dev.apnum.android.phone

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.provider.ContactsContract
import android.provider.Telephony
import android.telecom.TelecomManager
import android.provider.CallLog
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import dev.apnum.android.link.ErrorCode
import dev.apnum.android.link.Needs
import dev.apnum.android.link.PhoneTool
import dev.apnum.android.link.Schema
import dev.apnum.android.link.ToolException
import dev.apnum.android.link.ToolRegistry
import dev.apnum.android.link.int
import dev.apnum.android.link.invalidInput
import dev.apnum.android.link.long
import dev.apnum.android.link.bool
import dev.apnum.android.link.str
import dev.apnum.android.link.unavailable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** The v1 phone tools from docs/link-protocol.md, backed by Android APIs. */
class PhoneTools(
    private val ctx: Context,
    private val calls: CallMonitor,
    private val ringer: Ringer,
) {
    fun registerAll(registry: ToolRegistry) {
        val smsRead = listOf(Manifest.permission.READ_SMS)
        registry.register(
            PhoneTool("phone.info", "Phone model, Android version, battery percent and charging state, and network name.", "read", Schema.empty) { info() },
            PhoneTool(
                "phone.sms.list", "List recent SMS messages, newest first. Optional limit (default 20), address and sinceMs filters.", "read",
                Schema.obj(
                    "limit" to Schema.integer("Maximum messages, 1 to 200 (default 20)"),
                    "address" to Schema.string("Only messages to or from this number"),
                    "sinceMs" to Schema.integer("Only messages newer than this Unix time in milliseconds"),
                ),
                smsRead,
            ) { smsList(it) },
            PhoneTool(
                "phone.sms.send", "Send an SMS text message from the phone.", "dangerous",
                Schema.obj("to" to Schema.string("Phone number; spaces, dashes and brackets are ignored"), "body" to Schema.string("Message text"), required = listOf("to", "body")),
                listOf(Manifest.permission.SEND_SMS),
            ) { smsSend(it) },
            PhoneTool(
                "phone.otp.latest", "The most recent one-time code found in an SMS from the last 10 minutes: code, from, body, dateMs.", "read",
                Schema.empty, smsRead,
            ) { otpLatest() },
            PhoneTool(
                "phone.notifications.list", "List the phone's active notifications: key, app, title, text, postedMs.", "read", Schema.empty,
                listOf(Needs.NOTIFICATION_ACCESS),
            ) { notificationsList() },
            PhoneTool(
                "phone.notifications.dismiss", "Dismiss one notification by its key from phone.notifications.list.", "write",
                Schema.obj("key" to Schema.string("Notification key"), required = listOf("key")),
                listOf(Needs.NOTIFICATION_ACCESS),
            ) { notificationDismiss(it) },
            PhoneTool(
                "phone.notifications.clear", "Dismiss every notification on the phone that can be dismissed. Returns cleared (count).", "write", Schema.empty,
                listOf(Needs.NOTIFICATION_ACCESS),
            ) { notificationsClear() },
            PhoneTool(
                "phone.calls.recent", "Recent calls from the call log, newest first: number, contactName, type (incoming, outgoing, missed), dateMs, durationSec. Optional limit (default 20).", "read",
                Schema.obj("limit" to Schema.integer("Maximum calls, 1 to 200 (default 20)")),
                listOf(Manifest.permission.READ_CALL_LOG),
            ) { callsRecent(it) },
            PhoneTool(
                "phone.call.dial", "Start a phone call to a number.", "dangerous",
                Schema.obj("number" to Schema.string("Number to call"), required = listOf("number")),
                listOf(Manifest.permission.CALL_PHONE),
            ) { dial(it) },
            PhoneTool(
                "phone.call.end", "End the current call, or reject the ringing one.", "write", Schema.empty,
                listOf(Manifest.permission.ANSWER_PHONE_CALLS),
            ) { endCall() },
            PhoneTool(
                "phone.call.state", "Current call state: idle, ringing or offhook, with number when known.", "read", Schema.empty,
                listOf(Manifest.permission.READ_PHONE_STATE),
            ) { callState() },
            PhoneTool(
                "phone.contacts.search", "Find contacts whose name or number matches a query: name and numbers.", "read",
                Schema.obj("query" to Schema.string("Part of a name or number"), required = listOf("query")),
                listOf(Manifest.permission.READ_CONTACTS),
            ) { contactsSearch(it) },
            PhoneTool("phone.clipboard.get", "Read plain text from the phone clipboard. Android only allows this while apnum is on screen.", "read", Schema.empty) { clipboardGet() },
            PhoneTool(
                "phone.clipboard.set", "Put plain text on the phone clipboard.", "write",
                Schema.obj("text" to Schema.string("Text to copy"), required = listOf("text")),
            ) { clipboardSet(it) },
            PhoneTool(
                "phone.ring", "Ring the phone loudly for 30 seconds, even on silent, to find it. Pass stop: true to stop.", "write",
                Schema.obj("stop" to Schema.boolean("true to stop ringing")),
            ) { ring(it) },
        )
    }

    // region info

    private fun battery(): Pair<Int, Boolean> {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val plugged = (i?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        return (if (level < 0) -1 else level * 100 / scale) to plugged
    }

    private fun networkName(): String {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "Offline"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile data"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
            else -> "Connected"
        }
    }

    private fun info(): JsonElement {
        val (percent, charging) = battery()
        return buildJsonObject {
            put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            put("android", Build.VERSION.RELEASE)
            put("sdk", Build.VERSION.SDK_INT)
            put("batteryPercent", percent)
            put("charging", charging)
            put("network", networkName())
        }
    }

    // endregion

    // region sms

    private fun smsList(input: JsonObject): JsonElement {
        val limit = (input.int("limit") ?: 20).coerceIn(1, 200)
        val selection = StringBuilder("1=1")
        val args = mutableListOf<String>()
        input.long("sinceMs")?.let { selection.append(" AND date > ?"); args += it.toString() }
        input.str("address")?.takeIf { it.isNotBlank() }?.let {
            selection.append(" AND address LIKE ?"); args += "%" + it.filter(Char::isDigit).takeLast(10).ifEmpty { it }
        }
        return buildJsonObject { put("messages", querySms(selection.toString(), args, limit)) }
    }

    private fun querySms(selection: String, args: List<String>, limit: Int): JsonArray = buildJsonArray {
        val cursor = ctx.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
            selection, args.toTypedArray(), "date DESC",
        ) ?: return@buildJsonArray
        cursor.use {
            var n = 0
            while (n < limit && it.moveToNext()) {
                val address = it.getString(1)
                add(buildJsonObject {
                    put("id", it.getLong(0))
                    put("address", address)
                    put("contactName", contactName(address))
                    put("body", it.getString(2))
                    put("dateMs", it.getLong(3))
                    put("incoming", it.getInt(4) == Telephony.Sms.MESSAGE_TYPE_INBOX)
                })
                n++
            }
        }
    }

    private fun otpLatest(): JsonElement {
        val since = System.currentTimeMillis() - 10 * 60_000
        val cursor = ctx.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
            "date > ?", arrayOf(since.toString()), "date DESC",
        ) ?: throw unavailable("The SMS database could not be opened.")
        cursor.use {
            while (it.moveToNext()) {
                val body = it.getString(1) ?: continue
                val code = Otp.extract(body) ?: continue
                return buildJsonObject {
                    put("code", code); put("from", it.getString(0)); put("body", body); put("dateMs", it.getLong(2))
                }
            }
        }
        throw ToolException(ErrorCode.NotFound, "No one-time code arrived by SMS in the last 10 minutes.")
    }

    private fun smsSend(input: JsonObject): JsonElement {
        val to = PhoneNumber.normalize(input.str("to")) ?: throw invalidInput("This sender can't receive replies.")
        val body = input.str("body").orEmpty()
        if (body.isEmpty()) throw invalidInput("body must not be empty.")
        val sms = smsManager()
        val parts = sms.divideMessage(body)
        if (parts.size == 1) sms.sendTextMessage(to, null, body, null, null) else sms.sendMultipartTextMessage(to, null, parts, null, null)
        return buildJsonObject { put("sent", true); put("parts", parts.size) }
    }

    /** The SmsManager for the default SMS subscription, so dual-SIM phones send from the SIM the user chose for texts. */
    @Suppress("DEPRECATION")
    private fun smsManager(): SmsManager {
        val sub = runCatching { SubscriptionManager.getDefaultSmsSubscriptionId() }.getOrDefault(SubscriptionManager.INVALID_SUBSCRIPTION_ID)
        val valid = sub != SubscriptionManager.INVALID_SUBSCRIPTION_ID
        return when {
            Build.VERSION.SDK_INT >= 31 ->
                if (valid) ctx.getSystemService(SmsManager::class.java).createForSubscriptionId(sub) else ctx.getSystemService(SmsManager::class.java)
            valid -> SmsManager.getSmsManagerForSubscriptionId(sub)
            else -> SmsManager.getDefault()
        }
    }

    fun contactName(number: String?): String? {
        if (number.isNullOrBlank() || !Perms.has(ctx, Manifest.permission.READ_CONTACTS)) return null
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        return runCatching {
            ctx.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull()
    }

    // endregion

    // region notifications

    private fun notificationsList(): JsonElement {
        val listener = ApnumNotificationListener.instance
            ?: throw unavailable("Notification access is granted but the listener is not running yet. Toggle it off and on in Android settings.")
        return buildJsonObject {
            put("notifications", buildJsonArray {
                listener.activeNotifications.orEmpty().filter { it.packageName != ctx.packageName }.forEach { add(ApnumNotificationListener.describe(ctx, it)) }
            })
        }
    }

    private fun notificationDismiss(input: JsonObject): JsonElement {
        val key = input.str("key") ?: throw invalidInput("key is required.")
        val listener = ApnumNotificationListener.instance ?: throw unavailable("The notification listener is not running.")
        listener.cancelNotification(key)
        return buildJsonObject { put("dismissed", true) }
    }

    private fun notificationsClear(): JsonElement {
        val listener = ApnumNotificationListener.instance ?: throw unavailable("The notification listener is not running.")
        val own = ctx.packageName
        val cleared = NotificationClearer.clear(object : NotificationSurface {
            override fun active() = listener.activeNotifications.orEmpty().map { ActiveNotification(it.key, it.packageName == own, it.isClearable) }
            override fun cancel(key: String) = listener.cancelNotification(key)
        })
        return buildJsonObject { put("cleared", cleared) }
    }

    // endregion

    // region calls

    private fun callsRecent(input: JsonObject): JsonElement {
        val limit = (input.int("limit") ?: 20).coerceIn(1, 200)
        val entries = mutableListOf<CallEntry>()
        val cursor = ctx.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            null, null, "${CallLog.Calls.DATE} DESC",
        ) ?: throw unavailable("The call log could not be opened.")
        cursor.use {
            while (entries.size < limit && it.moveToNext()) {
                val number = it.getString(0)?.takeIf { n -> n.isNotBlank() }
                entries += CallEntry(number, it.getString(1)?.takeIf { n -> n.isNotBlank() }, CallLogJson.typeName(it.getInt(2)), it.getLong(3), it.getLong(4))
            }
        }
        return CallLogJson.toJson(entries)
    }

    private fun dial(input: JsonObject): JsonElement {
        val number = input.str("number")?.trim().orEmpty()
        if (!number.matches(Regex("""[+*#0-9 ()-]{2,30}"""))) throw invalidInput("number must be a phone number.")
        // TelecomManager.placeCall works from a background service where startActivity(ACTION_CALL) would be blocked.
        ctx.getSystemService(TelecomManager::class.java).placeCall(Uri.fromParts("tel", number, null), Bundle())
        return buildJsonObject { put("dialing", true) }
    }

    private fun endCall(): JsonElement {
        val ended = ctx.getSystemService(TelecomManager::class.java).endCall()
        return buildJsonObject { put("ended", ended) }
    }

    private fun callState(): JsonElement = buildJsonObject {
        put("state", calls.state)
        calls.number?.let { put("number", it) }
    }

    // endregion

    private fun contactsSearch(input: JsonObject): JsonElement {
        val q = input.str("query")?.trim().orEmpty()
        if (q.isEmpty()) throw invalidInput("query must not be empty.")
        val found = linkedMapOf<Long, Pair<String, MutableList<String>>>()
        val like = "%$q%"
        ctx.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.CONTACT_ID, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ? OR ${ContactsContract.CommonDataKinds.Phone.NUMBER} LIKE ?",
            arrayOf(like, like), "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use {
            while (it.moveToNext() && found.size < 50) {
                val entry = found.getOrPut(it.getLong(0)) { (it.getString(1) ?: "") to mutableListOf() }
                it.getString(2)?.let { n -> if (n !in entry.second) entry.second += n }
            }
        }
        return buildJsonObject {
            put("contacts", buildJsonArray {
                found.values.forEach { (name, numbers) ->
                    add(buildJsonObject { put("name", name); put("numbers", buildJsonArray { numbers.forEach { n -> add(JsonPrimitive(n)) } }) })
                }
            })
        }
    }

    // region clipboard

    private fun clipboardGet(): JsonElement {
        val cm = ctx.getSystemService(ClipboardManager::class.java)
        val text = runCatching { cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString() }.getOrNull()
        return text?.let { buildJsonObject { put("text", it) } }
            ?: throw unavailable(
                "Android 10 and later only let the app on screen read the clipboard. Open apnum on the phone and try again, or the clipboard is empty."
            )
    }

    private fun clipboardSet(input: JsonObject): JsonElement {
        val text = input.str("text") ?: throw invalidInput("text is required.")
        ClipboardSync.setPlain(ctx, text)
        return buildJsonObject { put("ok", true) }
    }

    // endregion

    private fun ring(input: JsonObject): JsonElement {
        if (input.bool("stop") == true) {
            ringer.stop()
            return buildJsonObject { put("ringing", false) }
        }
        ringer.start()
        return buildJsonObject { put("ringing", true); put("seconds", Ringer.SECONDS) }
    }
}
