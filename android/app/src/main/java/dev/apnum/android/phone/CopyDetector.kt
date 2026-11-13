package dev.apnum.android.phone

/** What the accessibility service passes in: only the few fields needed, no screen content. */
data class A11yEventData(
    val kind: Kind,
    val packageName: String?,
    val className: String?,
    /** Event text, content description and window title, taken from the event itself. */
    val texts: List<String>,
) {
    enum class Kind { WindowChange, Click, Other }
}

/**
 * Decides whether an accessibility event means "the user just copied text". Either the system clipboard preview
 * appeared (Android 13+, a window from System UI that names the clipboard), or a Copy / Cut control was clicked.
 * Repeated detections within [debounceMs] count once. [copyLabels] are the localised "Copy" and "Cut" strings.
 */
class CopyDetector(copyLabels: Collection<String>, private val ownPackage: String, private val debounceMs: Long = 1_200) {
    private val labels = copyLabels.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
    private var lastMs = Long.MIN_VALUE

    @Synchronized
    fun copied(e: A11yEventData, nowMs: Long): Boolean {
        if (e.packageName == ownPackage) return false
        val hit = when (e.kind) {
            A11yEventData.Kind.WindowChange -> isClipboardOverlay(e)
            A11yEventData.Kind.Click -> e.texts.any { it.trim().lowercase() in labels }
            A11yEventData.Kind.Other -> false
        }
        if (!hit) return false
        if (lastMs != Long.MIN_VALUE && nowMs - lastMs in 0 until debounceMs) return false
        lastMs = nowMs
        return true
    }

    private fun isClipboardOverlay(e: A11yEventData): Boolean {
        if (e.packageName != "com.android.systemui") return false
        return e.className?.contains("clipboard", ignoreCase = true) == true ||
            e.texts.any { it.contains("clipboard", ignoreCase = true) }
    }
}
