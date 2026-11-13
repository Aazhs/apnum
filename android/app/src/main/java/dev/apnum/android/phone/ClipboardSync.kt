package dev.apnum.android.phone

import android.app.Activity
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.service.quicksettings.TileService
import android.widget.Toast
import dev.apnum.android.ApnumApp
import dev.apnum.android.link.ConnectionState
import java.util.UUID

/**
 * Clipboard sync. Mac to phone: [applyFromMac] sets the clip and remembers it so it is not echoed back.
 * Phone to Mac: Android lets an app read the clipboard only in the foreground, so while apnum is on screen a listener
 * sends changes, and [ClipboardSendActivity] (Quick Settings tile, notification action) reads it once on demand.
 */
class ClipboardSync(private val ctx: Context, private val send: (text: String, id: String) -> Unit) {
    private val guard = ClipboardGuard()
    private val cm get() = ctx.getSystemService(ClipboardManager::class.java)
    private var listening = false
    private val listener = ClipboardManager.OnPrimaryClipChangedListener { sendCurrent() }

    fun applyFromMac(text: String) {
        if (text.length > ClipboardGuard.MAX_CHARS) return
        guard.receivedFromPeer(text)
        setPlain(ctx, text)
    }

    /** Called from onResume (true) and onPause (false) of the main activity. */
    @Synchronized
    fun foreground(on: Boolean) {
        if (on && !listening) {
            cm.addPrimaryClipChangedListener(listener); listening = true
            sendCurrent() // changed while we were away
        } else if (!on && listening) {
            cm.removePrimaryClipChangedListener(listener); listening = false
        }
    }

    /** Reads the clipboard (works only with focus or in the foreground) and sends it if it is new. Returns false when nothing was sent. */
    fun sendCurrent(): Boolean {
        val text = runCatching { cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString() }.getOrNull()
        if (!guard.shouldSend(text)) return false
        send(text!!, UUID.randomUUID().toString())
        return true
    }

    companion object {
        /** Plain text, flagged as not sensitive so Android shows the clip preview. */
        fun setPlain(ctx: Context, text: String) {
            val clip = ClipData.newPlainText("apnum", text)
            if (Build.VERSION.SDK_INT >= 33) {
                clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false) }
            }
            ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
        }

        fun sendIntent(ctx: Context): PendingIntent =
            PendingIntent.getActivity(ctx, 11, Intent(ctx, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
    }
}

/** Transparent: waits until it has focus (the only time Android lets it read the clipboard), sends once, finishes. */
class ClipboardSendActivity : Activity() {
    private var done = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val graph = ApnumApp.graph(this)
        val message = when {
            graph.link.connection.value != ConnectionState.Connected -> "Your Mac is not connected."
            graph.clipboard.sendCurrent() -> "Sent to your Mac."
            else -> "Nothing new to send."
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        finish()
    }
}

class SendClipboardTile : TileService() {
    @Suppress("DEPRECATION")
    override fun onClick() {
        val intent = Intent(this, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 12, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            startActivityAndCollapse(intent)
        }
    }
}
