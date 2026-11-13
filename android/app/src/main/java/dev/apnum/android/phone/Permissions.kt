package dev.apnum.android.phone

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.apnum.android.link.Needs

/** One row of the Permissions screen. */
enum class Capability(val title: String, val why: String, val runtime: List<String>) {
    LocalNetwork("Local network", "Lets the phone find and talk to your Mac on the same Wi-Fi. Android 17 asks for this.",
        if (Build.VERSION.SDK_INT >= 37) listOf("android.permission.ACCESS_LOCAL_NETWORK") else emptyList()),
    Sms("SMS", "Lets the Mac read your texts, find one-time codes, and send texts when you allow it.",
        listOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS)),
    Contacts("Contacts", "Shows names instead of numbers and lets the Mac search your contacts.", listOf(Manifest.permission.READ_CONTACTS)),
    Calls("Phone and calls", "Lets the Mac see call state, start a call, and hang up or reject one.",
        listOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.CALL_PHONE, Manifest.permission.ANSWER_PHONE_CALLS)),
    NotificationAccess("Notification access", "Lets the Mac see your phone's notifications and dismiss them.", emptyList()),
    PostNotifications("Show notifications", "Shows the small \"Connected to your Mac\" status.",
        if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()),
    Battery("Battery optimisation", "Keeps the link alive when the screen is off. Set it to unrestricted.", emptyList()),
}

object Perms {
    fun has(ctx: Context, permission: String): Boolean = when (permission) {
        Needs.NOTIFICATION_ACCESS -> notificationAccessGranted(ctx)
        else -> ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED
    }

    fun notificationAccessGranted(ctx: Context): Boolean =
        NotificationManagerCompat.getEnabledListenerPackages(ctx).contains(ctx.packageName)

    fun ignoringBatteryOptimisations(ctx: Context): Boolean =
        (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(ctx.packageName)

    fun granted(ctx: Context, c: Capability): Boolean = when (c) {
        Capability.NotificationAccess -> notificationAccessGranted(ctx)
        Capability.Battery -> ignoringBatteryOptimisations(ctx)
        Capability.PostNotifications -> c.runtime.all { has(ctx, it) } // true below Android 13
        else -> c.runtime.all { has(ctx, it) }
    }

    fun listenerComponent(ctx: Context) = ComponentName(ctx, ApnumNotificationListener::class.java)
}
