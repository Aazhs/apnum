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
                    val text = if (state == ConnectionState.Connected) "Connected to ${mac.name}" else "Looking for your Mac"
                    nm.notify(NOTIFICATION_ID, build(text))
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        return START_STICKY
    }

    override fun onDestroy() {
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

/** Starts the link after the phone boots, when a Mac is paired. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (ApnumApp.graph(context).store.load() != null) runCatching { LinkService.start(context) }
    }
}
