package dev.apnum.android.update

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

const val RELEASE_API_URL = "https://api.github.com/repos/Aazhs/apnum/releases/latest"
const val APK_ASSET_NAME = "apnum-android.apk"

data class ReleaseInfo(val tag: String, val notes: String, val pageUrl: String?, val apkUrl: String?, val apkSize: Long?)

sealed interface UpdateCheck {
    data object UpToDate : UpdateCheck
    data class Available(val release: ReleaseInfo) : UpdateCheck
    /** A newer release exists but it carries no phone APK. */
    data class NoApk(val release: ReleaseInfo) : UpdateCheck
}

object UpdateLogic {
    /** "v0.2.0" or "0.2.0" to numeric components; null when it is not a dotted number. */
    fun parseVersion(v: String): List<Int>? {
        val parts = v.trim().removePrefix("v").removePrefix("V").substringBefore('-').substringBefore('+').split('.')
        return parts.map { it.toIntOrNull() ?: return null }
    }

    /** Negative, zero or positive like compareTo. Missing components count as 0 ("1.2" equals "1.2.0"). Unparseable sorts lowest. */
    fun compare(a: String, b: String): Int {
        val x = parseVersion(a) ?: return if (parseVersion(b) == null) 0 else -1
        val y = parseVersion(b) ?: return 1
        for (i in 0 until maxOf(x.size, y.size)) {
            val c = x.getOrElse(i) { 0 }.compareTo(y.getOrElse(i) { 0 })
            if (c != 0) return c
        }
        return 0
    }

    /** Reads the GitHub "latest release" payload. Null when it is not a usable release. */
    fun parseRelease(json: String): ReleaseInfo? {
        val root = runCatching { Json.parseToJsonElement(json) as? JsonObject }.getOrNull() ?: return null
        val tag = root["tag_name"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() } ?: return null
        val assets = (root["assets"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
        val apk = assets.firstOrNull { it["name"]?.jsonPrimitive?.contentOrNull == APK_ASSET_NAME }
        return ReleaseInfo(
            tag = tag,
            notes = root["body"]?.jsonPrimitive?.contentOrNull.orEmpty().trim(),
            pageUrl = root["html_url"]?.jsonPrimitive?.contentOrNull,
            apkUrl = apk?.get("browser_download_url")?.jsonPrimitive?.contentOrNull,
            apkSize = apk?.get("size")?.jsonPrimitive?.longOrNull,
        )
    }

    fun decide(currentVersion: String, release: ReleaseInfo): UpdateCheck = when {
        compare(release.tag, currentVersion) <= 0 -> UpdateCheck.UpToDate
        release.apkUrl.isNullOrBlank() -> UpdateCheck.NoApk(release)
        else -> UpdateCheck.Available(release)
    }

    /** Only https downloads are followed. */
    fun isSafeDownload(url: String): Boolean = url.startsWith("https://")

    fun dueForAutoCheck(enabled: Boolean, lastCheckMs: Long, nowMs: Long): Boolean =
        enabled && (lastCheckMs <= 0 || nowMs - lastCheckMs >= 24L * 3600 * 1000 || nowMs < lastCheckMs)
}
