package dev.apnum.android

import dev.apnum.android.sky.Rgb
import dev.apnum.android.sky.SkyPalette
import dev.apnum.android.sky.SkyTheme
import dev.apnum.android.sky.Sun
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class SkyTest {
    private fun alt(iso: String) = Sun.altitudeDegrees(Instant.parse(iso).toEpochMilli(), Sun.PUNE_LAT, Sun.PUNE_LON)
    private fun deg(rad: Double) = rad * 180 / Math.PI

    // Reference values: Tests/ApnumSkyTests/Reference.swift (from the aarshj.me JavaScript), Pune, radians.
    @Test fun sunAltitudeMatchesSwiftReference() {
        assertEquals(deg(0.09555818549189722), alt("2026-11-12T12:00:00Z"), 1e-6)
        assertEquals(deg(-0.9487739552529187), alt("2026-08-12T20:00:00Z"), 1e-6)
        assertEquals(deg(0.38372625045125114), alt("2026-03-03T11:33:00Z"), 1e-6)
        assertEquals(deg(1.0667606855864609), alt("2026-05-31T05:00:00Z"), 1e-6)
    }

    @Test fun sunIsNearTheHorizonAtPuneSunrise() {
        // Sunrise in Pune on 12 Nov 2026 is about 06:42 IST = 01:12 UTC.
        assertTrue(Math.abs(alt("2026-11-12T01:12:00Z")) < 2.0)
    }

    @Test fun keyframesAreExact() {
        assertEquals(Rgb.hex("#5f4466"), SkyPalette.forSunAltitude(0.0).skyTop)
        assertEquals(Rgb.hex("#4a86d0"), SkyPalette.forSunAltitude(25.0).skyTop)
        assertEquals(Rgb.hex("#0d0b1f"), SkyPalette.forSunAltitude(-18.0).skyTop)
    }

    @Test fun altitudesClampAtBothEnds() {
        assertEquals(SkyPalette.forSunAltitude(25.0).near, SkyPalette.forSunAltitude(80.0).near)
        assertEquals(SkyPalette.forSunAltitude(-18.0).near, SkyPalette.forSunAltitude(-60.0).near)
    }

    @Test fun interpolatesBetweenKeyframes() {
        val mid = SkyPalette.forSunAltitude(3.5).skyTop
        val expected = Rgb.hex("#5f4466").mix(Rgb.hex("#6d86bf"), 0.5)
        assertEquals(expected.r, mid.r, 1e-12)
        assertEquals(expected.b, mid.b, 1e-12)
    }

    @Test fun themeFollowsTheRecipe() {
        // The theme uses the stretched (lingering) altitude so dawn and dusk colours last longer.
        val p = SkyPalette.forSunAltitude(SkyPalette.lingering(10.0))
        val t = SkyTheme.forSunAltitude(10.0)
        assertEquals(p.ground.mix(p.near, 0.25), t.background)
        assertEquals(p.near.mix(p.mid, 0.35), t.surface)
    }

    @Test fun dawnAndDuskColoursLinger() {
        assertEquals(0.0, SkyPalette.lingering(0.0), 1e-9)
        assertEquals(-18.0, SkyPalette.lingering(-40.0), 1e-9)
        assertEquals(25.0, SkyPalette.lingering(80.0), 1e-9)
        assertEquals(7.0, SkyPalette.lingering(13.0), 1e-9)
        assertEquals(25.0, SkyPalette.lingering(34.0), 1e-9)
        assertEquals(-6.0, SkyPalette.lingering(-9.5), 1e-9)
    }

    @Test fun accentIsSkyTopByDayPeakAtTwilightRimAtNight() {
        val day = SkyPalette.forSunAltitude(40.0)
        assertEquals(day.skyTop, SkyTheme.accent(day, 40.0))
        val dawn = SkyPalette.forSunAltitude(0.0)
        assertEquals(dawn.peak, SkyTheme.accent(dawn, 0.0))
        val night = SkyPalette.forSunAltitude(-30.0)
        assertEquals(night.rim, SkyTheme.accent(night, -30.0))
    }
}
