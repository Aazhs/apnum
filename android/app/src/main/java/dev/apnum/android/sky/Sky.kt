package dev.apnum.android.sky

import kotlin.math.PI
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/** An sRGB colour with components 0..1, mixed linearly like `RGB.mix` in ApnumSky. */
data class Rgb(val r: Double, val g: Double, val b: Double) {
    fun mix(other: Rgb, t: Double) = Rgb(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    fun toArgb(): Int {
        fun c(v: Double) = (v.coerceIn(0.0, 1.0) * 255 + 0.5).toInt()
        return (0xFF shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    companion object {
        fun hex(h: String): Rgb {
            val v = h.removePrefix("#").toInt(16)
            return Rgb((v shr 16 and 255) / 255.0, (v shr 8 and 255) / 255.0, (v and 255) / 255.0)
        }
    }
}

/** The 13 sky colours, in the order of `SkyPalette` in `Sources/ApnumSky/SkyModels.swift`. */
class SkyPalette(private val c: List<Rgb>) {
    val skyTop get() = c[0]
    val sky get() = c[1]
    val skyLow get() = c[2]
    val haze get() = c[3]
    val peak get() = c[7]
    val mid get() = c[9]
    val near get() = c[10]
    val ground get() = c[11]
    val rim get() = c[12]
    fun all() = c

    companion object {
        private fun frame(vararg hex: String) = SkyPalette(hex.map(Rgb::hex))

        /** Keyframes by sun altitude in degrees (aarshj.me `sky.js`). */
        val keyframes: List<Pair<Double, SkyPalette>> = listOf(
            -18.0 to frame("#0d0b1f", "#161433", "#221e45", "#2e2852", "#24213f", "#322e55", "#25234a", "#353262", "#262449", "#1b1936", "#131128", "#0c0b19", "#8c88c4"),
            -6.0 to frame("#2b2150", "#4a3666", "#7a4f78", "#9a6585", "#4f3b66", "#6a4f78", "#5c4470", "#86607e", "#644a6c", "#3c2a4e", "#2a1c38", "#1c1226", "#d9b7c8"),
            0.0 to frame("#5f4466", "#7b5a7e", "#a06e8c", "#b98299", "#7e5f86", "#93708f", "#8e5e7e", "#d88a86", "#b46f78", "#5e3a57", "#3f2740", "#2a1b2e", "#fff6e3"),
            7.0 to frame("#6d86bf", "#c9938a", "#efae84", "#ffd39b", "#d08a80", "#f6b99c", "#b07d8c", "#e09a7c", "#b2706a", "#6e4a5c", "#4a3044", "#2e1f2c", "#ffe8b8"),
            25.0 to frame("#4a86d0", "#68a2dc", "#94c2e8", "#c4e0f0", "#e4eef8", "#ffffff", "#8ea7c6", "#7391b2", "#5a7493", "#4b6a6c", "#33504a", "#22362e", "#f4fbff"),
        )

        /** The palette for a sun altitude, linearly interpolated between keyframes (clamped at both ends). */
        fun forSunAltitude(degrees: Double): SkyPalette {
            val alt = degrees.coerceIn(keyframes.first().first, keyframes.last().first)
            var i = 0
            while (i < keyframes.size - 2 && alt > keyframes[i + 1].first) i++
            val (a0, a) = keyframes[i]
            val (b0, b) = keyframes[i + 1]
            val t = (alt - a0) / (b0 - a0)
            return SkyPalette(a.all().zip(b.all()) { x, y -> x.mix(y, t) })
        }
    }
}

/** Sun altitude, ported from SunCalc as in `Astronomy.swift`. */
object Sun {
    private const val RAD = PI / 180
    private const val DAY_MS = 86_400_000.0
    private const val J1970 = 2_440_588.0
    private const val J2000 = 2_451_545.0
    private val OBLIQUITY = RAD * 23.4397

    /** Default place until the Mac says otherwise. */
    const val PUNE_LAT = 18.5204
    const val PUNE_LON = 73.8567

    /** Altitude of the sun's centre in degrees at [epochMs] for a place in degrees. */
    fun altitudeDegrees(epochMs: Long, latitude: Double, longitude: Double): Double {
        val d = epochMs / DAY_MS - 0.5 + J1970 - J2000
        val m = RAD * (357.5291 + 0.98560028 * d)
        val c = RAD * (1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m))
        val l = m + c + RAD * 102.9372 + PI
        val ra = atan2(sin(l) * cos(OBLIQUITY), cos(l))
        val dec = asin(sin(OBLIQUITY) * sin(l))
        val lw = RAD * -longitude
        val phi = RAD * latitude
        val h = RAD * (280.16 + 360.9856235 * d) - lw - ra
        return asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h)) / RAD
    }
}

/** The handful of sky colours the app theme uses. */
class SkyTheme(val background: Rgb, val surface: Rgb, val surfaceHigh: Rgb, val primary: Rgb, val sunAltitude: Double) {
    companion object {
        /** Accent: skyTop by day, peak near sunrise and sunset, rim at night, blended in between. */
        fun accent(p: SkyPalette, alt: Double): Rgb {
            var c = p.peak
            if (alt > 8) c = c.mix(p.skyTop, ((alt - 8) / 8).coerceIn(0.0, 1.0))
            if (alt < -4) c = c.mix(p.rim, ((-4 - alt) / 6).coerceIn(0.0, 1.0))
            return c
        }

        fun forSunAltitude(alt: Double): SkyTheme {
            val p = SkyPalette.forSunAltitude(alt)
            return SkyTheme(
                background = p.ground.mix(p.near, 0.25),
                surface = p.near.mix(p.mid, 0.35),
                surfaceHigh = p.near.mix(p.mid, 0.6),
                primary = accent(p, alt),
                sunAltitude = alt,
            )
        }
    }
}
