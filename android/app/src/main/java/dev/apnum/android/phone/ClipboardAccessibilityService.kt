package dev.apnum.android.phone

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import dev.apnum.android.ApnumApp
import dev.apnum.android.link.ConnectionState

/**
 * Opt-in. Notices that the user copied text, then reads the clipboard for the Mac. Android lets only the focused app
 * read the clipboard, so a 1x1 transparent accessibility overlay takes focus for a few milliseconds, reads, and goes.
 * It looks only at the package, class and short label of the event, never at the screen, and never logs anything.
 */
class ClipboardAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var detector: CopyDetector? = null
    private var reading = false

    override fun onServiceConnected() {
        // The label strings come from the system so they match the phone's language.
        val labels = listOf(android.R.string.copy, android.R.string.cut).map { getString(it) } + listOf("Copy", "Cut")
        detector = CopyDetector(labels, packageName)
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val graph = ApnumApp.graph(this)
        if (!graph.settings.autoClipboard || graph.store.load() == null) return
        val kind = when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> A11yEventData.Kind.WindowChange
            AccessibilityEvent.TYPE_VIEW_CLICKED -> A11yEventData.Kind.Click
            else -> return
        }
        val texts = buildList {
            event.text.forEach { add(it.toString()) }
            event.contentDescription?.let { add(it.toString()) }
        }
        val data = A11yEventData(kind, event.packageName?.toString(), event.className?.toString(), texts)
        if (detector?.copied(data, System.currentTimeMillis()) != true) return
        // A Copy tap sets the clip a moment after the click; the system preview appears after it is set.
        handler.postDelayed({ readClipboard() }, if (kind == A11yEventData.Kind.Click) 200L else 0L)
    }

    private fun readClipboard() {
        if (reading) return
        val graph = ApnumApp.graph(this)
        if (graph.link.connection.value != ConnectionState.Connected) return
        reading = true
        val wm = getSystemService(WindowManager::class.java)
        var view: View? = null
        var finished = false

        fun finish(ok: Boolean) {
            if (finished) return
            finished = true
            handler.removeCallbacksAndMessages(TIMEOUT_TOKEN)
            // Never remove the window from inside its own focus callback: Android is still handling that
            // focus change and crashes on the missing view (NullPointerException in ViewRootImpl). Remove it
            // on the next turn of the main loop instead.
            val toRemove = view
            view = null
            handler.post {
                toRemove?.let { runCatching { wm.removeView(it) } }
                reading = false
                if (!ok) fallbackToActivity()
            }
        }

        val overlay = object : View(this) {
            override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
                super.onWindowFocusChanged(hasWindowFocus)
                if (!hasWindowFocus || finished) return
                graph.clipboard.sendCurrent(auto = true)
                finish(true)
            }
        }
        view = overlay
        val lp = WindowManager.LayoutParams(
            1, 1, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        try {
            wm.addView(overlay, lp)
            handler.postAtTime({ finish(false) }, TIMEOUT_TOKEN, android.os.SystemClock.uptimeMillis() + 500)
        } catch (_: Exception) {
            finish(false)
        }
    }

    /** The overlay did not get focus on this phone: use the transparent activity instead, without a toast. */
    private fun fallbackToActivity() {
        runCatching {
            startActivity(Intent(this, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra(ClipboardSendActivity.EXTRA_QUIET, true))
        }
    }

    companion object {
        private val TIMEOUT_TOKEN = Any()
        @Volatile var instance: ClipboardAccessibilityService? = null

        fun enabled(ctx: Context): Boolean {
            val am = ctx.getSystemService(AccessibilityManager::class.java)
            val me = ComponentName(ctx, ClipboardAccessibilityService::class.java)
            return am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK).any {
                it.resolveInfo.serviceInfo.let { s -> s.packageName == me.packageName && s.name == me.className }
            }
        }
    }
}
