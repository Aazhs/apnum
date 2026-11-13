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
        val n = sbn.notification
        val ongoing = sbn.isOngoing || n.flags and Notification.FLAG_ONGOING_EVENT != 0 || n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0
        val summary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0
        reportOtpFromNotification(sbn)
        if (!NotificationFilter.mirror(sbn.packageName == packageName, ongoing, summary)) return
        ApnumApp.graph(this).link.sendEvent("notification.posted", describe(this, sbn))
    }

    /**
     * Fallback for Android versions that withhold the SMS broadcast: a code in the messaging app's notification is
     * reported as the same `sms.received` event, unless the broadcast already reported that code a moment ago.
     */
    private fun reportOtpFromNotification(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val defaultSms = runCatching { android.provider.Telephony.Sms.getDefaultSmsPackage(this) }.getOrNull()
        if (!OtpDedupe.isMessagingPackage(sbn.packageName, defaultSms)) return
        val graph = ApnumApp.graph(this)
        if (graph.store.load() == null) return
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: return
        val otp = Otp.extract(text) ?: return
        if (!graph.otpDedupe.firstReport(otp, System.currentTimeMillis())) return
        graph.link.sendEventReliably("sms.received", SmsReceiver.smsEvent(title, null, text, sbn.postTime, otp))
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
