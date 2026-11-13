package dev.apnum.android.link

/** Turns connection failures into one plain sentence for the user. */
object LinkErrors {
    const val LOCAL_NETWORK = "Allow apnum to find devices on your local network"

    fun describe(e: Throwable): String {
        val text = e.message.orEmpty()
        return when {
            e is SecurityException || text.contains("EPERM", true) || text.contains("Operation not permitted", true) -> LOCAL_NETWORK
            e is java.net.ConnectException || e is java.net.SocketTimeoutException || e is java.net.UnknownHostException ->
                "Could not reach the Mac at that address. Check that both devices are on the same network."
            e is kotlinx.coroutines.TimeoutCancellationException -> "The Mac did not answer in time."
            else -> "Could not connect (${e::class.java.simpleName})."
        }
    }
}
