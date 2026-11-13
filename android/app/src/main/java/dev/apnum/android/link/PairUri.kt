package dev.apnum.android.link

import java.net.URLDecoder
import java.util.Base64

/** What the Mac's QR code or link carries: `apnum://pair?v=1&host=&port=&pk=&token=&name=`. */
class PairInfo(val host: String, val port: Int, val publicKey: ByteArray, val token: ByteArray, val name: String) {
    val tokenText: String get() = Base64.getUrlEncoder().withoutPadding().encodeToString(token)
}

class PairUriException(message: String) : Exception(message)

object PairUri {
    fun looksLikePairUri(text: String?) = text != null && text.trim().startsWith("apnum://pair", ignoreCase = true)

    /** Same rules as the Rust `parse_pair_uri`: version 1, a 32-byte key and a non-empty token. */
    fun parse(uri: String): PairInfo {
        val text = uri.trim()
        if (!looksLikePairUri(text)) throw PairUriException("This is not an apnum pairing link.")
        val query = text.substringAfter('?', "")
        val params = query.split('&').filter { it.isNotEmpty() }.associate {
            it.substringBefore('=') to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }
        if (params["v"] != "1") throw PairUriException("This pairing link is from a different version of apnum.")
        val host = params["host"]?.trim()?.removePrefix("[")?.removeSuffix("]").orEmpty()
        if (host.isEmpty()) throw PairUriException("The pairing link has no address.")
        val port = params["port"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: throw PairUriException("The pairing link has a bad port.")
        val pk = decode(params["pk"]) ?: throw PairUriException("The pairing link has a bad key.")
        if (pk.size != 32) throw PairUriException("The pairing link has a bad key.")
        val token = decode(params["token"])?.takeIf { it.isNotEmpty() } ?: throw PairUriException("The pairing link has a bad token.")
        return PairInfo(host, port, pk, token, params["name"].orEmpty().ifBlank { "Mac" })
    }

    private fun decode(s: String?): ByteArray? = try {
        s?.let { Base64.getUrlDecoder().decode(it) }
    } catch (_: IllegalArgumentException) {
        null
    }

    /** Strips spaces and dashes from a typed code and checks it is 8 digits. */
    fun normalizeCode(text: String): String? = text.filter { !it.isWhitespace() && it != '-' }.takeIf { it.length == 8 && it.all(Char::isDigit) }

    /** "host", "host:port" or "[v6]:port" typed by hand; the port defaults to 47800. */
    fun parseAddress(text: String): Pair<String, Int>? {
        val t = text.trim()
        if (t.isEmpty()) return null
        if (t.startsWith("[")) {
            val host = t.substringAfter('[').substringBefore(']')
            val port = t.substringAfter("]:", "").ifEmpty { "47800" }.toIntOrNull() ?: return null
            return host.takeIf { it.isNotEmpty() }?.let { it to port }
        }
        if (t.count { it == ':' } > 1) return t to 47800 // bare IPv6
        val host = t.substringBefore(':')
        val port = if (':' in t) t.substringAfter(':').toIntOrNull() ?: return null else 47800
        return if (host.isNotEmpty() && port in 1..65535) host to port else null
    }
}
