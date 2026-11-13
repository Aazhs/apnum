package dev.apnum.android.update

import android.content.Context

/** Small on-device switches. Private preferences; nothing here leaves the phone. */
class AppSettings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("apnum_settings", Context.MODE_PRIVATE)

    /** Opt-in: send what is copied on the phone to the Mac, through the accessibility service. */
    var autoClipboard: Boolean
        get() = prefs.getBoolean("autoClipboard", false)
        set(v) = prefs.edit().putBoolean("autoClipboard", v).apply()

    var autoUpdateCheck: Boolean
        get() = prefs.getBoolean("autoUpdateCheck", true)
        set(v) = prefs.edit().putBoolean("autoUpdateCheck", v).apply()

    var lastUpdateCheckMs: Long
        get() = prefs.getLong("lastUpdateCheckMs", 0)
        set(v) = prefs.edit().putLong("lastUpdateCheckMs", v).apply()
}
