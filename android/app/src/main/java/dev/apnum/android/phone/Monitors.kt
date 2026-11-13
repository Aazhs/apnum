package dev.apnum.android.phone

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import androidx.core.app.NotificationCompat
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.BatteryManager
import android.os.Build
import android.provider.Telephony
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import dev.apnum.android.ApnumApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * `phone.ring`: the alarm stream at full volume for 30 seconds, which plays even when the phone is on silent.
 * [onChange] fires with the new state (the `ring` event); a notification with a Stop button shows while it rings.
 */
class Ringer(private val ctx: Context, private val scope: CoroutineScope, private val onChange: (Boolean) -> Unit = {}) {
    private var ringtone: Ringtone? = null
    private var savedVolume = -1
    private var timer: Job? = null
    @Volatile private var active = false

    val isRinging: Boolean get() = active

    @Synchronized
    fun start() {
        halt()
        val audio = ctx.getSystemService(AudioManager::class.java)
        savedVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) }
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val r = RingtoneManager.getRingtone(ctx, uri)
        r.audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
        r.isLooping = true
        r.play()
        ringtone = r
        active = true
        showNotification()
        timer = scope.launch { delay(SECONDS * 1000L); stop() }
        onChange(true)
    }

    /** Stops for sure: also when the ringtone object was lost or the timer already fired. */
    @Synchronized
    fun stop() {
        val was = active
        halt()
        if (was) onChange(false)
    }

    private fun halt() {
        timer?.cancel(); timer = null
        runCatching { ringtone?.stop() }
        ringtone = null
        active = false
        runCatching { ctx.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID) }
        if (savedVolume >= 0) {
            runCatching { ctx.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0) }
            savedVolume = -1
        }
    }

    private fun showNotification() = runCatching {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Find my phone", NotificationManager.IMPORTANCE_HIGH).apply { setSound(null, null) })
        val stop = PendingIntent.getBroadcast(ctx, 7, Intent(ctx, FindStopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        nm.notify(
            NOTIFICATION_ID,
            NotificationCompat.Builder(ctx, CHANNEL)
                .setSmallIcon(dev.apnum.android.R.drawable.ic_stat_link)
                .setContentTitle("Ringing so you can find me")
                .setOngoing(true).setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .addAction(0, "Stop", stop)
                .setContentIntent(stop)
                .build(),
        )
    }

    companion object {
        const val SECONDS = 30
        private const val CHANNEL = "find-phone"
        private const val NOTIFICATION_ID = 33
    }
}

/** Tracks call state for `phone.call.state` and the `call.state` event. Call [start] again after the permission is granted. */
class CallMonitor(private val ctx: Context, private val onChange: (state: String, number: String?) -> Unit) {
    @Volatile var state = "idle"; private set
    @Volatile var number: String? = null; private set
    private var started = false

    @Synchronized
    @Suppress("DEPRECATION")
    fun start() {
        if (started || !Perms.has(ctx, Manifest.permission.READ_PHONE_STATE)) return
        val tm = ctx.getSystemService(TelephonyManager::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            tm.registerTelephonyCallback(ContextCompat.getMainExecutor(ctx), object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(s: Int) = update(s, null)
            })
        } else {
            tm.listen(object : PhoneStateListener() {
                override fun onCallStateChanged(s: Int, phoneNumber: String?) = update(s, phoneNumber)
            }, PhoneStateListener.LISTEN_CALL_STATE)
        }
        started = true
    }

    private fun update(s: Int, num: String?) {
        val next = when (s) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
            else -> "idle"
        }
        val n = num?.takeIf { it.isNotBlank() && next != "idle" } ?: number.takeIf { next != "idle" && next != state }
        if (next == state && n == number) return
        state = next
        number = if (next == "idle") null else n
        onChange(state, number)
    }
}

/** Sends the `battery` event on 5% steps and plug changes. */
class BatteryMonitor(private val ctx: Context, private val onChange: (percent: Int, charging: Boolean) -> Unit) {
    private var lastStep = -1
    private var lastCharging: Boolean? = null
    private var registered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
            if (level < 0) return
            val percent = level * 100 / scale
            val charging = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
            val step = percent / 5
            if (step != lastStep || charging != lastCharging) {
                val first = lastStep < 0
                lastStep = step; lastCharging = charging
                if (!first) onChange(percent, charging)
            }
        }
    }

    @Synchronized
    fun start() {
        if (registered) return
        ContextCompat.registerReceiver(ctx, receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        registered = true
    }
}

/**
 * `sms.received`. Registered in the manifest, so it runs even when the app was not open. It works only from the
 * broadcast's PDUs (the SMS provider is written later) and hands the event to the link at once; when the link is
 * down the event is queued, the service is started and the reconnect backoff is skipped.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return
        val started = System.nanoTime()
        val graph = ApnumApp.graph(context)
        if (graph.store.load() == null) return
        val address = parts.first().originatingAddress
        val body = parts.joinToString("") { it.messageBody.orEmpty() }
        val otp = Otp.extract(body)
        if (otp != null) graph.otpDedupe.firstReport(otp, System.currentTimeMillis()) // so the notification fallback stays quiet
        graph.link.sendEventReliably("sms.received", smsEvent(address, quickContactName(graph.phoneTools, address), body, parts.first().timestampMillis, otp))
        runCatching { dev.apnum.android.LinkService.start(context) }
        // Timing only, never the message.
        runCatching { android.util.Log.d("apnum", "sms.received handled in ${(System.nanoTime() - started) / 1_000_000} ms, otp=${otp != null}, connected=${graph.link.isConnected}, lagVsSmsc=${System.currentTimeMillis() - parts.first().timestampMillis} ms") }
    }

    /** The contact lookup must never hold up a one-time code: wait at most 120 ms for it. */
    private fun quickContactName(tools: PhoneTools, address: String?): String? {
        if (address.isNullOrBlank()) return null
        val result = java.util.concurrent.CompletableFuture.supplyAsync { tools.contactName(address) }
        return runCatching { result.get(120, java.util.concurrent.TimeUnit.MILLISECONDS) }.getOrNull()
    }

    companion object {
        fun smsEvent(address: String?, contact: String?, body: String, dateMs: Long, otp: String?): JsonObject = buildJsonObject {
            put("address", address); put("contactName", contact); put("body", body); put("dateMs", dateMs)
            if (otp != null) put("otp", otp)
        }
    }
}

/** The Stop button on the "Ringing so you can find me" notification. */
class FindStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ApnumApp.graph(context).ringer.stop()
    }
}
