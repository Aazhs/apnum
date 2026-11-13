package dev.apnum.android.alarm

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import dev.apnum.android.ApnumApp
import dev.apnum.android.MainActivity
import dev.apnum.android.R
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId

/** Schedules the next wake-up with the system alarm clock (which also shows the alarm icon in the status bar). */
class AlarmScheduler(private val context: Context, private val repo: AlarmRepository) {
    private val am = context.getSystemService(AlarmManager::class.java)

    fun reschedule() {
        val plan = AlarmLogic.plan(repo.store.live.value, repo.snoozedUntil(), Instant.now(), ZoneId.systemDefault())
        val pi = ringIntent()
        if (plan == null) {
            am.cancel(pi)
            return
        }
        val show = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java).putExtra("tab", "alarms"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        try {
            am.setAlarmClock(AlarmManager.AlarmClockInfo(plan.at.toEpochMilli(), show), pi.also { })
        } catch (_: SecurityException) {
            // Exact alarms were revoked; the Permissions screen explains how to restore them.
        }
        nextAt = plan.at
    }

    @Volatile var nextAt: Instant? = null
        private set

    private fun ringIntent(): PendingIntent {
        val i = Intent(context, AlarmReceiver::class.java).setAction(ACTION_RING)
        return PendingIntent.getBroadcast(context, 1, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    companion object {
        const val ACTION_RING = "dev.apnum.android.RING"
    }
}

/** The scheduled time arrived: work out which alarm is due and start ringing. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val graph = ApnumApp.graph(context)
        graph.alarmController.ringDue(Instant.now())
    }
}

/** Reschedules after reboot, app update, clock change and time-zone change. */
class AlarmRescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val graph = ApnumApp.graph(context)
        graph.alarmScheduler.reschedule()
        if (intent.action == Intent.ACTION_BOOT_COMPLETED && graph.store.load() != null) {
            runCatching { dev.apnum.android.LinkService.start(context) }
        }
    }
}

/** Buttons on the ringing notification and the timer notification. */
class RingActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val graph = ApnumApp.graph(context)
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        when (intent.action) {
            ACTION_STOP -> graph.alarmController.stop(id)
            ACTION_SNOOZE -> graph.alarmController.snooze(id)
            ACTION_STOP_TIMER -> graph.scope.launch { runCatching { graph.link.callMac("timer.stop", kotlinx.serialization.json.buildJsonObject { put("id", kotlinx.serialization.json.JsonPrimitive(id)) }) } }
        }
    }

    companion object {
        const val EXTRA_ID = "id"
        const val ACTION_STOP = "dev.apnum.android.ALARM_STOP"
        const val ACTION_SNOOZE = "dev.apnum.android.ALARM_SNOOZE"
        const val ACTION_STOP_TIMER = "dev.apnum.android.TIMER_STOP"

        fun intent(context: Context, action: String, id: String, code: Int): PendingIntent {
            val i = Intent(context, RingActionReceiver::class.java).setAction(action).putExtra(EXTRA_ID, id)
            return PendingIntent.getBroadcast(context, code, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }
}

object AlarmNotifications {
    const val CHANNEL = "alarm"
    const val CHANNEL_TIMER = "timer"
    const val RING_ID = 2
    const val TIMER_ID = 3
    const val MISSED_ID = 4

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Alarms", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Ringing alarms"
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setBypassDnd(true)
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_TIMER, "Mac timers", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Shown when a timer on your Mac goes off"
        })
    }

    fun ringing(context: Context, r: Ringing): Notification {
        val screen = PendingIntent.getActivity(context, 2, Intent(context, RingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle(r.label.ifBlank { "Alarm" })
            .setContentText("%02d:%02d".format(r.hour, r.minute))
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(screen)
            .setFullScreenIntent(screen, true)
            .addAction(0, "Stop", RingActionReceiver.intent(context, RingActionReceiver.ACTION_STOP, r.id, 10))
        if (r.canSnooze) b.addAction(0, "Snooze", RingActionReceiver.intent(context, RingActionReceiver.ACTION_SNOOZE, r.id, 11))
        return b.build()
    }

    fun canUseFullScreen(context: Context): Boolean =
        Build.VERSION.SDK_INT < 34 || context.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()
}

/** Plays the alarm sound with rising volume and vibrates until stopped. */
class RingPlayer(private val context: Context) {
    private var player: MediaPlayer? = null
    private var ramp: Job? = null

    fun start(scope: kotlinx.coroutines.CoroutineScope) {
        if (player != null) return
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(context, uri)
                isLooping = true
                setVolume(0.1f, 0.1f)
                prepare()
                start()
            }
        }.getOrNull()
        ramp = scope.launch {
            var v = 0.1f
            while (isActive && v < 1f) {
                delay(2_000)
                v = (v + 0.06f).coerceAtMost(1f)
                runCatching { player?.setVolume(v, v) }
            }
        }
        runCatching {
            val vib = context.getSystemService(VibratorManager::class.java).defaultVibrator
            vib.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 700, 500), 0), AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
        }
    }

    fun stop() {
        ramp?.cancel(); ramp = null
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
        runCatching { context.getSystemService(VibratorManager::class.java).defaultVibrator.cancel() }
    }
}

/** Foreground service that rings: sound, vibration and the full-screen notification. */
class RingService : LifecycleService() {
    private lateinit var player: RingPlayer

    override fun onCreate() {
        super.onCreate()
        AlarmNotifications.createChannels(this)
        player = RingPlayer(this)
        val graph = ApnumApp.graph(this)
        val first = graph.alarmController.ringing.value.firstOrNull() ?: Ringing("", "Alarm", 0, 0)
        ServiceCompat.startForeground(this, AlarmNotifications.RING_ID, AlarmNotifications.ringing(this, first), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        lifecycleScope.launch {
            graph.alarmController.ringing.collect { list ->
                if (list.isEmpty()) {
                    player.stop()
                    ServiceCompat.stopForeground(this@RingService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    getSystemService(NotificationManager::class.java).notify(AlarmNotifications.RING_ID, AlarmNotifications.ringing(this@RingService, list.first()))
                    player.start(lifecycleScope)
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        player.stop()
        super.onDestroy()
    }

    companion object {
        fun start(context: Context) = ContextCompat.startForegroundService(context, Intent(context, RingService::class.java))
    }
}

/** The Android side of [RingEnvironment]. */
class AndroidRingEnvironment(
    private val context: Context,
    private val link: dev.apnum.android.link.LinkClient,
    private val scheduler: () -> AlarmScheduler,
) : RingEnvironment {
    override suspend fun callMac(tool: String, input: kotlinx.serialization.json.JsonObject) { link.callMac(tool, input) }
    override fun sendEvent(topic: String, data: kotlinx.serialization.json.JsonObject) = link.sendEvent(topic, data)
    override fun ensureServiceRunning() { runCatching { RingService.start(context) } }
    override fun rescheduleAlarms() = scheduler().reschedule()

    private val timerSound = RingPlayer(context)
    private val timerScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default)

    override fun showTimers(items: List<MacRingingItem>) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (items.isEmpty()) {
            nm.cancel(AlarmNotifications.TIMER_ID)
            timerSound.stop()
            return
        }
        // A finished timer rings like an alarm (alarm stream) until it is stopped here or on the Mac.
        timerSound.start(timerScope)
        AlarmNotifications.createChannels(context)
        val t = items.first()
        val n = NotificationCompat.Builder(context, AlarmNotifications.CHANNEL_TIMER)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle(t.title.ifBlank { "Timer" })
            .setContentText(t.body.ifBlank { "Your Mac's timer is done" })
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(true)
            .addAction(0, "Stop", RingActionReceiver.intent(context, RingActionReceiver.ACTION_STOP_TIMER, t.id, 20))
            .build()
        runCatching { nm.notify(AlarmNotifications.TIMER_ID, n) }
    }

    override fun showMissed(r: Ringing) {
        AlarmNotifications.createChannels(context)
        val n = NotificationCompat.Builder(context, AlarmNotifications.CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle("Missed alarm")
            .setContentText("%02d:%02d %s".format(r.hour, r.minute, r.label).trim())
            .setAutoCancel(true)
            .build()
        runCatching { context.getSystemService(NotificationManager::class.java).notify(AlarmNotifications.MISSED_ID, n) }
    }
}
