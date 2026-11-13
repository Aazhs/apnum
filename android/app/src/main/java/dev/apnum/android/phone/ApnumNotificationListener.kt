package dev.apnum.android.phone

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import dev.apnum.android.ApnumApp
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Reads the phone's notifications for the Mac. Needs "Notification access" in system settings. */
class ApnumNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        instance = this
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        ApnumApp.graph(this).link.sendEvent("notification.posted", describe(this, sbn))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        ApnumApp.graph(this).link.sendEvent("notification.removed", describe(this, sbn))
    }

    companion object {
        @Volatile var instance: ApnumNotificationListener? = null

        fun describe(ctx: Context, sbn: StatusBarNotification): JsonObject {
            val extras = sbn.notification.extras
            val pm = ctx.packageManager
            val app = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(sbn.packageName, 0)).toString() }.getOrDefault(sbn.packageName)
            return buildJsonObject {
                put("key", sbn.key)
                put("app", app)
                put("title", extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
                put("text", extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
                put("postedMs", sbn.postTime)
            }
        }
    }
}
