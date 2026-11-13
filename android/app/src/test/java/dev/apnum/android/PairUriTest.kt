package dev.apnum.android

import dev.apnum.android.link.PairUri
import dev.apnum.android.link.PairUriException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

class PairUriTest {
    private val enc = Base64.getUrlEncoder().withoutPadding()
    private val key = ByteArray(32) { it.toByte() }
    private val token = ByteArray(16) { (it * 3).toByte() }
    private fun uri(
        v: String = "1", host: String = "192.168.1.20", port: String = "47800", pk: String = enc.encodeToString(key),
        tk: String = enc.encodeToString(token), name: String = "Aarsh%27s%20MacBook",
    ) = "apnum://pair?v=$v&host=$host&port=$port&pk=$pk&token=$tk&name=$name"

    @Test fun parsesAValidLink() {
        val info = PairUri.parse(uri())
        assertEquals("192.168.1.20", info.host)
        assertEquals(47800, info.port)
        assertArrayEquals(key, info.publicKey)
        assertArrayEquals(token, info.token)
        assertEquals("Aarsh's MacBook", info.name)
        assertEquals(enc.encodeToString(token), info.tokenText)
    }

    @Test fun ipv6HostBracketsAreRemoved() = assertEquals("fe80::1", PairUri.parse(uri(host = "[fe80::1]")).host)

    @Test fun rejectsWrongVersion() = rejects(uri(v = "2"))
    @Test fun rejectsShortKey() = rejects(uri(pk = enc.encodeToString(ByteArray(16))))
    @Test fun rejectsBadBase64() = rejects(uri(pk = "!!!"))
    @Test fun rejectsBadPort() = rejects(uri(port = "99999"))
    @Test fun rejectsMissingToken() = rejects(uri(tk = ""))
    @Test fun rejectsOtherSchemes() = rejects("https://example.com/pair?v=1")

    @Test fun recognisesLinks() {
        assertTrue(PairUri.looksLikePairUri(" apnum://pair?v=1 "))
        assertFalse(PairUri.looksLikePairUri("apnum://other"))
        assertFalse(PairUri.looksLikePairUri(null))
    }

    @Test fun codeNormalisation() {
        assertEquals("12345678", PairUri.normalizeCode("1234 5678"))
        assertEquals("12345678", PairUri.normalizeCode("1234-5678"))
        assertNull(PairUri.normalizeCode("1234567"))
        assertNull(PairUri.normalizeCode("1234567a"))
    }

    @Test fun addressParsing() {
        assertEquals("192.168.1.20" to 47800, PairUri.parseAddress("192.168.1.20"))
        assertEquals("mac.local" to 5000, PairUri.parseAddress(" mac.local:5000 "))
        assertEquals("fe80::1" to 47801, PairUri.parseAddress("[fe80::1]:47801"))
        assertNull(PairUri.parseAddress(""))
        assertNull(PairUri.parseAddress("host:notaport"))
    }

    private fun rejects(text: String) {
        try {
            PairUri.parse(text)
            fail("expected PairUriException for $text")
        } catch (_: PairUriException) {
        }
    }
}
