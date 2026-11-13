package dev.apnum.android.link

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import uniffi.apnum_link.Handshake
import uniffi.apnum_link.Session
import uniffi.apnum_link.safetyNumber
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

enum class ConnectionState { Unpaired, Searching, Connecting, Connected }

sealed interface PairingState {
    data object Idle : PairingState
    data object Connecting : PairingState
    /** Code path: show this 6-digit number and ask the user whether it matches the Mac's screen. */
    data class ConfirmSafetyNumber(val number: String) : PairingState
    data object Done : PairingState
    data class Failed(val message: String) : PairingState
}

class MacEvent(val topic: String, val data: JsonObject)

/**
 * The phone's end of the link: Noise XX initiator over a WebSocket, pairing, reconnecting, and
 * symmetric calls and events. Holds no Android types, so it can be driven from a JVM test.
 */
class LinkClient(
    private val identity: Identity,
    private val store: MacStore,
    private val registry: ToolRegistry,
    private val device: DeviceInfo,
    private val discovery: MacDiscovery,
    private val scope: CoroutineScope,
    private val http: OkHttpClient = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(0, TimeUnit.MILLISECONDS).build(),
) : dev.apnum.android.sync.MacCaller {
    private val _connection = MutableStateFlow(if (store.load() == null) ConnectionState.Unpaired else ConnectionState.Searching)
    val connection: StateFlow<ConnectionState> = _connection.asStateFlow()

    private val _paired = MutableStateFlow(store.load())
    val pairedMac: StateFlow<PairedMac?> = _paired.asStateFlow()

    private val _macDevice = MutableStateFlow<DeviceInfo?>(null)
    val macDevice: StateFlow<DeviceInfo?> = _macDevice.asStateFlow()

    private val _macTools = MutableStateFlow<List<ToolDescriptor>>(emptyList())
    val macTools: StateFlow<List<ToolDescriptor>> = _macTools.asStateFlow()

    private val _pairing = MutableStateFlow<PairingState>(PairingState.Idle)
    val pairing: StateFlow<PairingState> = _pairing.asStateFlow()

    private val _events = MutableSharedFlow<MacEvent>(extraBufferCapacity = 64)
    val macEvents: SharedFlow<MacEvent> = _events.asSharedFlow()

    /** Android 17 blocks local network access until the user allows it; sessions wait for this (a test or older Android sets it true). */
    private val localNetworkAllowed = MutableStateFlow(true)
    fun setLocalNetworkAllowed(allowed: Boolean) { localNetworkAllowed.value = allowed; if (allowed) wake.trySend(Unit) }

    override val isConnected: Boolean get() = active != null
    override fun hasTool(name: String): Boolean = _macTools.value.any { it.name == name }
    override suspend fun call(tool: String, input: JsonObject): JsonElement = callMac(tool, input)

    private class Active(val ws: WebSocket, val session: Session)

    @Volatile private var active: Active? = null
    private val sendLock = Any()
    @Volatile private var lastSentMs = 0L
    @Volatile private var lastReceivedMs = 0L

    private val nextId = AtomicLong(0)
    private val pending = ConcurrentHashMap<Long, CompletableDeferred<JsonObject>>()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var loopJob: Job? = null
    private var pairJob: Job? = null
    private var confirmation: CompletableDeferred<Boolean>? = null

    // region lifecycle

    /** Starts connecting to the paired Mac, if there is one. Safe to call repeatedly. */
    fun start() {
        if (store.load() == null) {
            _connection.value = ConnectionState.Unpaired
            return
        }
        if (loopJob?.isActive == true || pairJob?.isActive == true) return
        loopJob = scope.launch { reconnectLoop() }
    }

    fun stop() {
        loopJob?.cancel()
        pairJob?.cancel()
        active?.ws?.cancel()
    }

    /** The default network changed or came back: retry now instead of waiting out the backoff. */
    fun networkChanged(lost: Boolean) {
        if (lost) active?.ws?.cancel()
        wake.trySend(Unit)
    }

    /** Tells the Mac this phone's tool list changed (for example after a permission was granted). */
    fun refreshTools() {
        sendJson(Messages.tools(registry.descriptors()))
    }

    fun unpair() {
        scope.launch {
            pairJob?.cancel()
            loopJob?.cancel()
            if (sendJson(Messages.bye("unpair"))) delay(250)
            active?.ws?.cancel()
            store.clear()
            reset(ConnectionState.Unpaired)
        }
    }

    private fun reset(state: ConnectionState) {
        _paired.value = store.load()
        _connection.value = state
        _macDevice.value = null
        _macTools.value = emptyList()
    }

    // endregion

    // region pairing

    /** QR or link: the Mac's key is known and checked. */
    fun pair(info: PairInfo) = beginPairing(info.host, info.port, info.publicKey, info.tokenText)

    /** Typed address and 8-digit code: the user confirms the safety number. */
    fun pairWithCode(host: String, port: Int, code: String) = beginPairing(host, port, null, code)

    fun confirmSafetyNumber(matches: Boolean) {
        confirmation?.complete(matches)
    }

    fun cancelPairing() {
        pairJob?.cancel()
        _pairing.value = PairingState.Idle
        start()
    }

    fun dismissPairingResult() {
        if (_pairing.value is PairingState.Failed || _pairing.value is PairingState.Done) _pairing.value = PairingState.Idle
    }

    /**
     * Every new link, scan or typed code replaces whatever pairing was in progress: the old attempt is cancelled,
     * its pending safety-number question and error are dropped, and only this attempt may report a result.
     */
    private fun beginPairing(host: String, port: Int, expectedKey: ByteArray?, token: String) {
        val previous = pairJob
        val previousLoop = loopJob
        val mine = pairGeneration.incrementAndGet()
        confirmation?.complete(false)
        confirmation = null
        _pairing.value = PairingState.Connecting
        pairJob = scope.launch {
            previous?.cancelAndJoin()
            previousLoop?.cancelAndJoin()
            if (mine != pairGeneration.get()) return@launch
            _pairing.value = PairingState.Connecting
            val outcome = if (awaitLocalNetwork()) runSession(host, port, expectedKey, Pairing(token)) else Outcome.Failed(LinkErrors.LOCAL_NETWORK)
            if (mine == pairGeneration.get()) {
                if (outcome is Outcome.Failed && _pairing.value !is PairingState.Done) _pairing.value = PairingState.Failed(outcome.message)
                if (store.load() != null) loopJob = scope.launch { reconnectLoop() }
            }
        }
    }

    private val pairGeneration = AtomicLong(0)

    private suspend fun awaitLocalNetwork(): Boolean =
        localNetworkAllowed.value || withTimeoutOrNull(LOCAL_NETWORK_WAIT_MS) { localNetworkAllowed.first { it } } == true

    private class Pairing(val token: String)

    // endregion

    // region calls and events

    suspend fun callMac(tool: String, input: JsonObject = JsonObject(emptyMap())): JsonElement {
        val id = nextId.incrementAndGet()
        val reply = CompletableDeferred<JsonObject>()
        pending[id] = reply
        try {
            if (!sendJson(Messages.call(id, tool, input))) throw unavailable("The Mac is not connected.")
            val result = withTimeoutOrNull(CALL_TIMEOUT_MS) { reply.await() } ?: throw unavailable("The Mac did not answer within 30 seconds.")
            return Messages.unwrapResult(result)
        } finally {
            pending.remove(id)
        }
    }

    fun sendEvent(topic: String, data: JsonObject) {
        sendJson(Messages.event(topic, data))
    }

    private val outbox = dev.apnum.android.phone.EventQueue()

    /**
     * Sends now when connected. Otherwise keeps the event (the last 20, for 10 minutes), starts the connection
     * and skips any backoff wait; the event goes out right after the next hello.
     */
    fun sendEventReliably(topic: String, data: JsonObject) {
        if (sendJson(Messages.event(topic, data))) return
        outbox.add(topic, data)
        start()
        wake.trySend(Unit)
        // Raced with a connection that came up between the failed send and the add.
        if (active != null) flushOutbox()
    }

    private fun flushOutbox() {
        outbox.drain().forEach { sendJson(Messages.event(it.topic, it.data)) }
    }

    private fun sendJson(o: JsonObject): Boolean = synchronized(sendLock) {
        val a = active ?: return false
        lastSentMs = nowMs()
        a.ws.send(a.session.seal(Messages.encode(o)).toByteString())
    }

    // endregion

    // region connection loop

    private sealed interface Outcome {
        /** Was connected and the session has since ended. */
        data object Ended : Outcome
        data object Unreachable : Outcome
        data class Failed(val message: String) : Outcome
    }

    private suspend fun reconnectLoop() {
        var backoff = INITIAL_BACKOFF_MS
        while (scope.isActive) {
            val mac = store.load() ?: return reset(ConnectionState.Unpaired)
            _paired.value = mac
            var outcome: Outcome = Outcome.Unreachable
            if (!awaitLocalNetwork()) {
                _connection.value = ConnectionState.Searching
                withTimeoutOrNull(MAX_BACKOFF_MS) { wake.receive() }
                continue
            }
            if (mac.host.isNotBlank()) {
                _connection.value = ConnectionState.Connecting
                outcome = runSession(mac.host, mac.port, mac.publicKey, null)
            }
            if (outcome == Outcome.Unreachable) {
                _connection.value = ConnectionState.Searching
                val found = discover(mac.id)
                if (found != null && (found.host != mac.host || found.port != mac.port)) {
                    _connection.value = ConnectionState.Connecting
                    outcome = runSession(found.host, found.port, mac.publicKey, null)
                    if (outcome == Outcome.Ended) store.load()?.let { store.save(PairedMac(it.id, it.name, it.publicKey, found.host, found.port)) }
                }
            }
            if (store.load() == null) return reset(ConnectionState.Unpaired)
            backoff = if (outcome == Outcome.Ended) INITIAL_BACKOFF_MS else minOf(backoff * 2, MAX_BACKOFF_MS)
            _connection.value = ConnectionState.Searching
            withTimeoutOrNull(backoff) { wake.receive() }
        }
    }

    private suspend fun discover(macId: String): FoundMac? {
        discovery.start()
        try {
            return withTimeoutOrNull(DISCOVERY_MS) {
                discovery.found.first { list -> list.any { it.id == null || it.id == macId } }
                    .first { it.id == null || it.id == macId }
            }
        } finally {
            discovery.stop()
        }
    }

    private fun request(host: String, port: Int): Request {
        val url = HttpUrl.Builder().scheme("http").host(host).port(port).addPathSegment("link").build()
        return Request.Builder().url(url).build()
    }

    private suspend fun recv(frames: Channel<ByteArray>): ByteArray = withTimeout(HANDSHAKE_TIMEOUT_MS) { frames.receive() }

    /**
     * One connection from socket open to close. With [pairing] set it also runs the pairing exchange.
     * [expectedKey] is the Mac's static key when known; null means "trust after the user confirms the safety number".
     */
    private suspend fun runSession(host: String, port: Int, expectedKey: ByteArray?, pairing: Pairing?): Outcome = supervisorScope {
        val frames = Channel<ByteArray>(Channel.UNLIMITED)
        val ws = http.newWebSocket(request(host, port), object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { frames.trySend(bytes.toByteArray()) }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null); frames.close() }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { frames.close() }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { frames.close(t) }
        })
        var connected = false
        try {
            val hs = Handshake.initiator(identity.privateKey)
            ws.send(hs.writeMessage().toByteString())
            hs.readMessage(recv(frames))
            ws.send(hs.writeMessage().toByteString())
            if (!hs.isFinished()) return@supervisorScope Outcome.Failed("The secure handshake did not finish.")
            val remoteKey = hs.remotePublicKey() ?: return@supervisorScope Outcome.Failed("The Mac did not send its key.")
            if (expectedKey != null && !remoteKey.contentEquals(expectedKey)) {
                return@supervisorScope if (pairing != null) {
                    Outcome.Failed("The Mac's key does not match the code. Scan the code again.")
                } else {
                    Outcome.Unreachable // another Mac or an impostor: never talk to it
                }
            }
            val safety = safetyNumber(hs.handshakeHash())
            val session = hs.intoSession()

            var macInfo: DeviceInfo? = null
            if (pairing != null) {
                if (expectedKey == null) {
                    val answer = CompletableDeferred<Boolean>().also { confirmation = it }
                    _pairing.value = PairingState.ConfirmSafetyNumber(safety)
                    val ok = withTimeoutOrNull(CONFIRM_TIMEOUT_MS) { answer.await() } ?: false
                    confirmation = null
                    if (!ok) return@supervisorScope Outcome.Failed("The safety numbers did not match, so nothing was paired.")
                    _pairing.value = PairingState.Connecting
                }
                ws.send(session.seal(Messages.encode(Messages.pair(pairing.token, device))).toByteString())
                val reply = Messages.decode(session.open(recv(frames)))
                if (reply == null || Messages.type(reply) != "paired") return@supervisorScope Outcome.Failed("The Mac sent an unexpected reply.")
                if (reply.bool("ok") != true) return@supervisorScope Outcome.Failed(reply.str("error") ?: "The Mac refused the pairing.")
                macInfo = DeviceInfo.fromJson(reply.obj("device"))
                store.save(PairedMac(macInfo?.id ?: host, macInfo?.name ?: "Mac", remoteKey, host, port))
                _paired.value = store.load()
                _pairing.value = PairingState.Done
            }

            active = Active(ws, session)
            connected = true
            lastReceivedMs = nowMs()
            lastSentMs = nowMs()
            _macDevice.value = macInfo
            _connection.value = ConnectionState.Connected
            val toolList = registry.descriptors()
            sendJson(Messages.hello(device, toolList))
            runCatching { android.util.Log.d("apnum", "hello tools: " + toolList.joinToString(",") { it.name }) }
            flushOutbox()

            val heartbeat = launch {
                while (isActive) {
                    delay(HEARTBEAT_TICK_MS)
                    val now = nowMs()
                    if (now - lastReceivedMs > SILENCE_MS) { ws.cancel(); break }
                    if (now - lastSentMs >= PING_MS) sendJson(Messages.ping())
                }
            }
            try {
                for (frame in frames) {
                    lastReceivedMs = nowMs()
                    val m = Messages.decode(session.open(frame)) ?: continue
                    if (!handle(m)) break
                }
            } finally {
                heartbeat.cancel()
            }
            Outcome.Ended
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (connected) Outcome.Ended else if (pairing != null) Outcome.Failed(describe(e)) else Outcome.Unreachable
        } finally {
            active = null
            if (connected) {
                _macDevice.value = null
                _macTools.value = emptyList()
            }
            pending.values.forEach { it.completeExceptionally(unavailable("The connection to the Mac was lost.")) }
            coroutineContext.cancelChildren()
            ws.cancel()
        }
    }

    /** Handles one incoming message; false ends the session. */
    private fun CoroutineScope.handle(m: JsonObject): Boolean {
        when (Messages.type(m)) {
            "hello" -> {
                DeviceInfo.fromJson(m.obj("device"))?.let { _macDevice.value = it }
                _macTools.value = ToolDescriptor.listFromJson(m["tools"])
            }
            "tools" -> _macTools.value = ToolDescriptor.listFromJson(m["tools"])
            "call" -> launch { sendJson(registry.handleCall(m)) }
            "result" -> m.long("id")?.let { pending[it]?.complete(m) }
            "event" -> m.str("topic")?.let { _events.tryEmit(MacEvent(it, m.obj("data") ?: JsonObject(emptyMap()))) }
            "ping" -> sendJson(Messages.pong())
            "bye" -> {
                if (m.str("reason") == "unpair") {
                    store.clear()
                    reset(ConnectionState.Unpaired)
                }
                return false
            }
        }
        return true
    }

    private fun describe(e: Exception): String {
        // The exception type and system message only (an address and errno); never message contents.
        runCatching { android.util.Log.w("apnum", "link connect failed: ${e.javaClass.name}: ${e.message}") }
        return LinkErrors.describe(e)
    }

    // endregion

    companion object {
        const val CALL_TIMEOUT_MS = 30_000L
        const val PING_MS = 20_000L
        const val SILENCE_MS = 45_000L
        const val HEARTBEAT_TICK_MS = 5_000L
        const val INITIAL_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 30_000L
        private const val DISCOVERY_MS = 4_000L
        private const val HANDSHAKE_TIMEOUT_MS = 10_000L
        private const val CONFIRM_TIMEOUT_MS = 120_000L
        private const val LOCAL_NETWORK_WAIT_MS = 60_000L

        private fun nowMs() = System.nanoTime() / 1_000_000
    }
}
