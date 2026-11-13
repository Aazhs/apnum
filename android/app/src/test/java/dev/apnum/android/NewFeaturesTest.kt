package dev.apnum.android

import dev.apnum.android.phone.A11yEventData
import dev.apnum.android.phone.CopyDetector
import dev.apnum.android.phone.OtpDedupe
import dev.apnum.android.update.UpdateCheck
import dev.apnum.android.update.UpdateLogic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OtpDedupeTest {
    @Test fun broadcastThenNotificationIsOneEvent() {
        val d = OtpDedupe()
        assertTrue(d.firstReport("123456", 1_000))
        assertFalse(d.firstReport("123456", 5_000))
    }

    @Test fun notificationOnlyIsOneEvent() {
        val d = OtpDedupe()
        assertTrue(d.firstReport("654321", 0))
    }

    @Test fun differentCodesAreTwoEvents() {
        val d = OtpDedupe()
        assertTrue(d.firstReport("111111", 0))
        assertTrue(d.firstReport("222222", 10))
    }

    @Test fun sameCodeAfterTheWindowIsReportedAgain() {
        val d = OtpDedupe()
        assertTrue(d.firstReport("111111", 0))
        assertFalse(d.firstReport("111111", 119_000))
        assertTrue(d.firstReport("111111", 121_000))
    }

    @Test fun messagingPackages() {
        assertTrue(OtpDedupe.isMessagingPackage("com.example.sms", "com.example.sms"))
        assertTrue(OtpDedupe.isMessagingPackage("com.google.android.apps.messaging", null))
        assertFalse(OtpDedupe.isMessagingPackage("com.whatsapp", "com.google.android.apps.messaging"))
    }
}

class CopyDetectorTest {
    private val own = "dev.apnum.android"
    private fun detector() = CopyDetector(listOf("Copy", "Cut", "Kopieren"), own, debounceMs = 1_000)
    private fun click(text: String, pkg: String = "com.app") = A11yEventData(A11yEventData.Kind.Click, pkg, "android.widget.Button", listOf(text))
    private fun overlay(cls: String = "com.android.systemui.clipboardoverlay.ClipboardOverlay", pkg: String = "com.android.systemui") =
        A11yEventData(A11yEventData.Kind.WindowChange, pkg, cls, emptyList())

    @Test fun copyAndCutClicksCount() {
        val d = detector()
        assertTrue(d.copied(click("Copy"), 0))
        assertTrue(d.copied(click(" cut "), 5_000))
        assertTrue(d.copied(click("Kopieren"), 10_000))
    }

    @Test fun otherClicksDoNot() {
        assertFalse(detector().copied(click("Paste"), 0))
        assertFalse(detector().copied(click("Copy link address"), 0))
    }

    @Test fun clipboardOverlayCounts() {
        assertTrue(detector().copied(overlay(), 0))
        assertTrue(detector().copied(A11yEventData(A11yEventData.Kind.WindowChange, "com.android.systemui", "android.widget.FrameLayout", listOf("Clipboard")), 0))
    }

    @Test fun otherSystemUiWindowsAndOtherAppsDoNot() {
        assertFalse(detector().copied(overlay(cls = "com.android.systemui.volume.VolumeDialog"), 0))
        assertFalse(detector().copied(overlay(pkg = "com.app"), 0))
    }

    @Test fun clickThenOverlayIsOneCopy() {
        val d = detector()
        assertTrue(d.copied(click("Copy"), 0))
        assertFalse(d.copied(overlay(), 400))
        assertTrue(d.copied(overlay(), 1_500))
    }

    @Test fun ownAppIsIgnored() {
        assertFalse(detector().copied(click("Copy", own), 0))
    }

    @Test fun otherEventsIgnored() {
        assertFalse(detector().copied(A11yEventData(A11yEventData.Kind.Other, "com.app", null, listOf("Copy")), 0))
    }
}

class UpdateLogicTest {
    private val payload = """
        {"url":"https://api.github.com/repos/Aazhs/apnum/releases/1","html_url":"https://github.com/Aazhs/apnum/releases/tag/v0.2.0",
         "id":1,"tag_name":"v0.2.0","name":"apnum 0.2.0","draft":false,"prerelease":false,
         "body":"- Update button\r\n- Faster codes",
         "assets":[
          {"name":"apnum-mac.zip","size":100,"browser_download_url":"https://github.com/Aazhs/apnum/releases/download/v0.2.0/apnum-mac.zip"},
          {"name":"apnum-android.apk","size":12345678,"content_type":"application/vnd.android.package-archive","browser_download_url":"https://github.com/Aazhs/apnum/releases/download/v0.2.0/apnum-android.apk"}
         ]}
    """.trimIndent()

    @Test fun versionsCompareNumerically() {
        assertTrue(UpdateLogic.compare("v0.10.0", "0.9.9") > 0)
        assertTrue(UpdateLogic.compare("0.2.0", "0.10.0") < 0)
        assertEquals(0, UpdateLogic.compare("v1.2", "1.2.0"))
        assertTrue(UpdateLogic.compare("1.0.1", "1.0") > 0)
        assertTrue(UpdateLogic.compare("2.0.0-beta", "1.9.9") > 0)
        assertTrue(UpdateLogic.compare("garbage", "0.1.0") < 0)
    }

    @Test fun parsesRealisticPayload() {
        val r = UpdateLogic.parseRelease(payload)!!
        assertEquals("v0.2.0", r.tag)
        assertEquals("https://github.com/Aazhs/apnum/releases/download/v0.2.0/apnum-android.apk", r.apkUrl)
        assertEquals(12345678L, r.apkSize)
        assertEquals("https://github.com/Aazhs/apnum/releases/tag/v0.2.0", r.pageUrl)
        assertTrue(r.notes.startsWith("- Update button"))
    }

    @Test fun newerWithApkIsAvailable() {
        val d = UpdateLogic.decide("0.1.0", UpdateLogic.parseRelease(payload)!!)
        assertTrue(d is UpdateCheck.Available)
    }

    @Test fun sameOrOlderIsUpToDate() {
        val r = UpdateLogic.parseRelease(payload)!!
        assertEquals(UpdateCheck.UpToDate, UpdateLogic.decide("0.2.0", r))
        assertEquals(UpdateCheck.UpToDate, UpdateLogic.decide("0.3.0", r))
    }

    @Test fun releaseWithoutPhoneApk() {
        val r = UpdateLogic.parseRelease("""{"tag_name":"v0.3.0","body":"","html_url":"x","assets":[{"name":"apnum-mac.zip","browser_download_url":"https://x/y.zip"}]}""")!!
        assertNull(r.apkUrl)
        assertTrue(UpdateLogic.decide("0.1.0", r) is UpdateCheck.NoApk)
    }

    @Test fun badPayloads() {
        assertNull(UpdateLogic.parseRelease("not json"))
        assertNull(UpdateLogic.parseRelease("""{"message":"Not Found"}"""))
        assertNotNull(UpdateLogic.parseRelease("""{"tag_name":"v1.0.0"}"""))
    }

    @Test fun onlyHttpsDownloads() {
        assertTrue(UpdateLogic.isSafeDownload("https://github.com/a.apk"))
        assertFalse(UpdateLogic.isSafeDownload("http://github.com/a.apk"))
    }

    @Test fun dailyCheckSchedule() {
        val day = 24L * 3600 * 1000
        assertTrue(UpdateLogic.dueForAutoCheck(true, 0, 1_000))
        assertFalse(UpdateLogic.dueForAutoCheck(true, 1_000, 1_000 + day - 1))
        assertTrue(UpdateLogic.dueForAutoCheck(true, 1_000, 1_000 + day))
        assertFalse(UpdateLogic.dueForAutoCheck(false, 0, day * 5))
    }
}
