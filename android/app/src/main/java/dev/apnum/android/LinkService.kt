package dev.apnum.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import dev.apnum.android.link.ConnectionState
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Keeps the link to the Mac alive when the app is closed. It owns nothing itself: the [LinkClient] lives in
 * [AppGraph], and this service is what keeps the process running and the status notification visible.
 */
class LinkService : LifecycleService() {
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = ApnumApp.graph(this@LinkService).link.networkChanged(lost = false)
        override fun onLost(network: Network) = ApnumApp.graph(this@LinkService).link.networkChanged(lost = true)
    }

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Link to your Mac", NotificationManager.IMPORTANCE_MIN).apply { setShowBadge(false) }
        )
        ServiceCompat.startForeground(this, NOTIFICATION_ID, build("Looking for your Mac"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)

        val graph = ApnumApp.graph(this)
        if (graph.store.load() == null) {
            stopSelf()
            return
        }
        graph.link.start()
        graph.startMonitors()
        runCatching { connectivity.registerDefaultNetworkCallback(networkCallback) }
        lifecycleScope.launch {
            combine(graph.link.connection, graph.link.pairedMac) { state, mac -> state to mac }.collect { (state, mac) ->
                if (mac == null) {
                    stopSelf()
                } else {
                    val connected = state == ConnectionState.Connected
                    setHeld(connected)
                    nm.notify(NOTIFICATION_ID, build(if (connected) "Connected to ${mac.name}" else "Looking for your Mac"))
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        // Started again (by an SMS, the app opening, a boot): reconnect now instead of waiting out a backoff.
        ApnumApp.graph(this).link.apply { start(); networkChanged(lost = false) }
        return START_STICKY
    }

    /**
     * While connected, hold a partial wake lock (so the 20 s ping and incoming frames are handled with the screen
     * off) and a low-latency Wi-Fi lock (so the radio does not sleep between packets). Both are released when the
     * link is down, so an unreachable Mac costs no battery.
     */
    @Suppress("DEPRECATION")
    private fun setHeld(on: Boolean) {
        if (on) {
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "apnum:link").apply { setReferenceCounted(false); acquire() }
            }
            if (wifiLock == null) {
                val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
                wifiLock = runCatching {
                    (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createWifiLock(mode, "apnum:link").apply { setReferenceCounted(false); acquire() }
                }.getOrNull()
            }
        } else {
            runCatching { wakeLock?.release() }; wakeLock = null
            runCatching { wifiLock?.release() }; wifiLock = null
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onDestroy() {
        setHeld(false)
        runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        super.onDestroy()
    }

    private fun build(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle("apnum")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(open)
            .addAction(0, "Send clipboard to Mac", dev.apnum.android.phone.ClipboardSync.sendIntent(this))
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        private const val CHANNEL = "link"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, LinkService::class.java))
        }
    }
}
