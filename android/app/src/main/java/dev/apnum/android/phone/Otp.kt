package dev.apnum.android.phone

/**
 * Finds a one-time code in an SMS body. A number only counts when the message talks about codes
 * (OTP, verification, password...) and the number is not an amount, a date, a phone or account number.
 */
object Otp {
    private val candidate = Regex("""(?<!\d)(\d{3}[ -]\d{3}|\d{4,8})(?!\d)""")
    private val strong = Regex("""\b(otp|one[- ]?time|code|verification|verify|password|passcode|pin|authenticat\w*|security code)\b""", RegexOption.IGNORE_CASE)
    private val weak = Regex("""\b(log ?in|sign ?in|confirm|register|transaction|txn|authori[sz]e)\b""", RegexOption.IGNORE_CASE)
    private val phoneSpan = Regex("""\+?\d[\d ()-]{8,}\d""")
    private val currencyBefore = Regex("""(\b(rs\.?|inr|usd|eur|gbp|amount|amt|bal(ance)?|worth)|[$€£₹])\s*[:.]?\s*$""", RegexOption.IGNORE_CASE)
    private val accountBefore = Regex("""(\b(ending( with| in)?|a/c|acct?|account|card|x+|no\.?|ref(erence)?|id|order)|[*#]+)\s*[:#.]?\s*$""", RegexOption.IGNORE_CASE)
    private val unitAfter = Regex("""^\s*(min|mins|minutes?|sec|secs|seconds?|hrs?|hours?|days?|rs\b|inr\b|%|am\b|pm\b|km|kg)""", RegexOption.IGNORE_CASE)
    private val introBefore = Regex("""(is|use|enter|otp|code|pin|password|passcode)\s*[:\-]?\s*$""", RegexOption.IGNORE_CASE)
    private val useBefore = Regex("""(use|enter|submit)\s*[:\-]?\s*$""", RegexOption.IGNORE_CASE)
    private val introAfter = Regex("""^\s*(is|as|to|will)\b""", RegexOption.IGNORE_CASE)

    fun extract(body: String): String? {
        val hasStrong = strong.containsMatchIn(body)
        val hasWeak = weak.containsMatchIn(body)
        if (!hasStrong && !hasWeak) return null
        val phones = phoneSpan.findAll(body).filter { m -> m.value.count(Char::isDigit) >= 10 }.map { it.range }.toList()

        var best: String? = null
        var bestScore = 0
        for (m in candidate.findAll(body)) {
            val range = m.range
            if (phones.any { range.first >= it.first && range.last <= it.last }) continue
            val before = body.substring(0, range.first)
            val after = body.substring(range.last + 1)
            if (isDateOrDecimal(before, after)) continue
            if (currencyBefore.containsMatchIn(before) || accountBefore.containsMatchIn(before.takeLast(14))) continue
            if (unitAfter.containsMatchIn(after)) continue

            var score = if (hasStrong) 2 else 1
            if (strong.containsMatchIn(before.takeLast(40)) || strong.containsMatchIn(after.take(40))) score += 1
            score += when {
                useBefore.containsMatchIn(before.takeLast(10)) -> 2
                introBefore.containsMatchIn(before.takeLast(12)) -> 1
                else -> 0
            }
            if (introAfter.containsMatchIn(after.take(8))) score += 1
            if (score >= 3 && score > bestScore) {
                best = m.value.filter(Char::isDigit)
                bestScore = score
            }
        }
        return best
    }

    private fun isDateOrDecimal(before: String, after: String): Boolean {
        val b = before.takeLast(2)
        val a = after.take(2)
        // 12/11/2026, 12-11-2026, 1,234.50, 99.5. A dash after a letter ("G-123456") is not a date.
        if (a.length == 2 && a[0] in "/-.:," && a[1].isDigit()) return true
        if (b.length == 2 && b[1] in "/-.:," && b[0].isDigit()) return true
        return false
    }
}
