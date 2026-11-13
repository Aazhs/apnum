package dev.apnum.android.phone

/**
 * The SMS broadcast and the messaging app's notification can both report the same one-time code (Android 17
 * withholds the broadcast from some apps, so the notification is the fallback). A code is reported once per window.
 */
class OtpDedupe(private val windowMs: Long = WINDOW_MS) {
    private val seen = HashMap<String, Long>()

    /** True the first time [code] is seen within the window; records it. */
    @Synchronized
    fun firstReport(code: String, nowMs: Long): Boolean {
        seen.entries.removeAll { nowMs - it.value >= windowMs || nowMs < it.value - windowMs }
        if (seen.containsKey(code)) return false
        seen[code] = nowMs
        return true
    }

    companion object {
        const val WINDOW_MS = 120_000L

        /** Messaging apps whose notifications are checked besides the default SMS app. */
        val KNOWN_MESSAGE_PACKAGES = setOf(
            "com.google.android.apps.messaging", "com.android.messaging", "com.samsung.android.messaging",
            "com.android.mms", "com.motorola.messaging",
        )

        fun isMessagingPackage(pkg: String, defaultSms: String?): Boolean = pkg == defaultSms || pkg in KNOWN_MESSAGE_PACKAGES
    }
}
