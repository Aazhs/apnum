package dev.apnum.android.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import dev.apnum.android.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

sealed interface UpdateUi {
    data object Idle : UpdateUi
    data object Checking : UpdateUi
    data object UpToDate : UpdateUi
    data class Available(val release: ReleaseInfo) : UpdateUi
    data class NoApk(val release: ReleaseInfo) : UpdateUi
    data class Downloading(val release: ReleaseInfo, val fraction: Float?) : UpdateUi
    data class Installing(val release: ReleaseInfo) : UpdateUi
    data class Failed(val message: String) : UpdateUi
}

/**
 * The one network call besides the Mac link. Runs only when the user taps "Check for updates" or, if enabled,
 * about once a day. It never downloads on its own: the APK is fetched only after "Update now".
 */
class Updater(private val app: Context, private val scope: CoroutineScope, private val settings: AppSettings) {
    private val _state = MutableStateFlow<UpdateUi>(UpdateUi.Idle)
    val state: StateFlow<UpdateUi> = _state

    private val http by lazy {
        OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()
    }

    fun autoCheckIfDue() {
        if (!UpdateLogic.dueForAutoCheck(settings.autoUpdateCheck, settings.lastUpdateCheckMs, System.currentTimeMillis())) return
        check()
    }

    fun check() {
        if (_state.value is UpdateUi.Checking || _state.value is UpdateUi.Downloading) return
        _state.value = UpdateUi.Checking
        scope.launch {
            _state.value = withContext(Dispatchers.IO) {
                runCatching {
                    val req = Request.Builder().url(RELEASE_API_URL).header("User-Agent", "apnum").header("Accept", "application/vnd.github+json").build()
                    http.newCall(req).execute().use { r ->
                        if (r.code == 404) return@use UpdateUi.UpToDate // no release published yet
                        if (!r.isSuccessful) return@use UpdateUi.Failed("GitHub answered ${r.code}. Try again later.")
                        val release = UpdateLogic.parseRelease(r.body.string()) ?: return@use UpdateUi.Failed("The release information was not readable.")
                        settings.lastUpdateCheckMs = System.currentTimeMillis()
                        when (val d = UpdateLogic.decide(BuildConfig.VERSION_NAME, release)) {
                            UpdateCheck.UpToDate -> UpdateUi.UpToDate
                            is UpdateCheck.Available -> UpdateUi.Available(d.release)
                            is UpdateCheck.NoApk -> UpdateUi.NoApk(d.release)
                        }
                    }
                }.getOrElse { UpdateUi.Failed("Could not reach GitHub. Check your connection.") }
            }
        }
    }

    fun canInstall(): Boolean = app.packageManager.canRequestPackageInstalls()

    fun openInstallPermission() {
        app.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun update(release: ReleaseInfo) {
        val url = release.apkUrl ?: return
        if (!UpdateLogic.isSafeDownload(url)) { _state.value = UpdateUi.Failed("The download address is not secure."); return }
        if (_state.value is UpdateUi.Downloading) return
        _state.value = UpdateUi.Downloading(release, null)
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val file = File(app.cacheDir, "update/$APK_ASSET_NAME").also { it.parentFile?.mkdirs() }
                    download(url, file, release)
                    install(file)
                    null
                }.getOrElse { it.message?.takeIf { m -> m.length < 120 } ?: "The update could not be downloaded." }
            }
            if (result != null) _state.value = UpdateUi.Failed(result) else _state.value = UpdateUi.Installing(release)
        }
    }

    private fun download(url: String, dest: File, release: ReleaseInfo) {
        http.newCall(Request.Builder().url(url).header("User-Agent", "apnum").build()).execute().use { r ->
            if (!r.isSuccessful) error("The download failed (${r.code}).")
            val total = r.body.contentLength().takeIf { it > 0 } ?: release.apkSize
            var done = 0L
            r.body.byteStream().use { input ->
                dest.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    var lastReport = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        val now = System.nanoTime()
                        if (now - lastReport > 100_000_000L) {
                            lastReport = now
                            _state.value = UpdateUi.Downloading(release, total?.let { (done.toFloat() / it).coerceIn(0f, 1f) })
                        }
                    }
                }
            }
        }
    }

    /** One PackageInstaller session; Android shows its own single confirmation. */
    private fun install(file: File) {
        val installer = app.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(app.packageName)
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            file.inputStream().use { input -> session.openWrite("apnum", 0, file.length()).use { out -> input.copyTo(out); session.fsync(out) } }
            val intent = Intent(app, InstallResultReceiver::class.java).setPackage(app.packageName)
            val pi = PendingIntent.getBroadcast(app, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            session.commit(pi.intentSender)
        }
    }

    internal fun installResult(status: Int, message: String?) {
        when (status) {
            PackageInstaller.STATUS_SUCCESS -> { _state.value = UpdateUi.Idle; File(app.cacheDir, "update/$APK_ASSET_NAME").delete() }
            PackageInstaller.STATUS_FAILURE_ABORTED -> _state.value = UpdateUi.Failed("The update was cancelled.")
            PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
                _state.value = UpdateUi.Failed("Android refused it. An update must be signed with the same key as the installed apnum.")
            else -> _state.value = UpdateUi.Failed(message?.takeIf { it.length < 120 } ?: "The install did not finish.")
        }
    }
}

/** Receives the installer's status. The system asks for confirmation through the intent it hands back. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) else intent.getParcelableExtra(Intent.EXTRA_INTENT) as Intent?
            runCatching { context.startActivity(confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            return
        }
        dev.apnum.android.ApnumApp.graph(context).updater.installResult(status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE))
    }
}
