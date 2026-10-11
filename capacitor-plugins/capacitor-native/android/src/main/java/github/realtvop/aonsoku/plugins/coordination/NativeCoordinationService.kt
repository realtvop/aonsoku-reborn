package github.realtvop.aonsoku.plugins.coordination

import android.os.Handler
import android.os.Looper
import android.util.Log
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.audio.AudioRemotePlaybackSnapshot
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import github.realtvop.aonsoku.plugins.audio.AudioCommandResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

data class NativeCoordinationEvent(val name: String, val payload: JSONObject)
data class CoordinationHttpResponse(val status: Int, val statusText: String, val body: String)

/** Application-owned protocol engine. Capacitor is an independent adapter. */
class NativeCoordinationService(private val context: Context) : CoordinationService {
    private val commandScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _events = MutableSharedFlow<NativeCoordinationEvent>(extraBufferCapacity = 128)
    val events = _events.asSharedFlow()
    private val _state = MutableStateFlow("disconnected")
    val state = _state.asStateFlow()
    private fun emit(name: String, payload: JSONObject) {
        if (name == "coordinationStateChange") _state.value = payload.optString("state")
        _events.tryEmit(NativeCoordinationEvent(name, payload))
    }
    companion object {
        @Volatile private var instance: NativeCoordinationService? = null
        fun getInstance(context: Context): NativeCoordinationService = instance ?: synchronized(this) {
            instance ?: NativeCoordinationService(context.applicationContext).also {
                instance = it
                AppServices.getInstance(context).registerCoordinationService(it)
            }
        }

        private const val TAG = "CoordPlugin"
        internal const val PREFS_NAME = "aonsoku_coordination"
        internal const val KEY_SERVER_URL = "server_url"
        internal const val KEY_IDENTITY_URL = "identity_url"
        /// Design §9.2: client sends heartbeat every 15 seconds.
        internal const val HEARTBEAT_INTERVAL_SECONDS = 15L
        internal const val SNAPSHOT_HEARTBEAT_MS = 10_000L
        /// OkHttp keep-alive ping to detect dead connections faster.
        internal const val PING_INTERVAL_SECONDS = 15L
        /// §13: exponential backoff. Base 1s, doubled per attempt, capped at 30s.
        internal const val BASE_RECONNECT_DELAY_MS = 1000L
        internal const val MAX_RECONNECT_DELAY_MS = 30_000L
        internal const val MAX_RECONNECT_ATTEMPTS = 10
        /// §9.1 dedup cache cap.
        internal const val DEDUP_CACHE_MAX = 200

        /// Design §9.2: heartbeat envelope. messageId is assigned at send time.
        internal fun buildHeartbeatEnvelope(protocolVersion: Int): JSONObject {
            val env = JSONObject()
            env.put("version", protocolVersion)
            env.put("messageId", java.util.UUID.randomUUID().toString())
            env.put("type", "heartbeat")
            return env
        }

        internal fun buildHelloEnvelope(
            protocolVersion: Int,
            capabilities: Int,
            deviceId: String,
            ticket: String,
            lastSeq: Long,
        ): JSONObject {
            val env = JSONObject()
            env.put("version", protocolVersion)
            env.put("messageId", java.util.UUID.randomUUID().toString())
            env.put("type", "hello")
            env.put("protocolVersion", protocolVersion)
            env.put("capabilities", capabilities)
            env.put("deviceId", deviceId)
            env.put("ticket", ticket)
            env.put("lastSeq", lastSeq)
            return env
        }

        internal fun buildTargetReadyEnvelope(
            protocolVersion: Int,
            transactionId: String,
            generation: Int,
            snapshotRevision: Int,
            sourceDeviceId: String,
            sessionId: String,
        ): JSONObject {
            val env = JSONObject()
            env.put("version", protocolVersion)
            env.put("messageId", java.util.UUID.randomUUID().toString())
            env.put("type", "target_ready")
            env.put("transactionId", transactionId)
            env.put("generation", generation)
            env.put("snapshotRevision", snapshotRevision)
            env.put("sourceDeviceId", sourceDeviceId)
            env.put("sessionId", sessionId)
            return env
        }

        internal fun buildCommandAckEnvelope(
            protocolVersion: Int,
            messageId: String,
            result: JSONObject = JSONObject().put("status", "ok"),
        ): JSONObject {
            val env = JSONObject()
            env.put("version", protocolVersion)
            env.put("messageId", messageId)
            env.put("type", "command_ack")
            env.put("result", result)
            return env
        }

        internal fun buildRelinquishAckEnvelope(
            protocolVersion: Int,
            transactionId: String,
            snapshot: JSONObject,
        ): JSONObject {
            val env = JSONObject()
            env.put("version", protocolVersion)
            env.put("messageId", java.util.UUID.randomUUID().toString())
            env.put("type", "relinquish_ack")
            env.put("transactionId", transactionId)
            env.put("snapshot", snapshot)
            return env
        }

        internal fun buildHandoffFailedEnvelope(
            protocolVersion: Int,
            transactionId: String,
            code: String,
        ): JSONObject {
            val env = JSONObject()
            env.put("version", protocolVersion)
            env.put("messageId", java.util.UUID.randomUUID().toString())
            env.put("type", "handoff_failed")
            env.put("transactionId", transactionId)
            env.put("code", code)
            return env
        }

        internal fun buildPlaybackSnapshot(
            sessionId: String,
            audioState: JSONObject,
            sampledAtSeconds: Double,
            volume: Double? = null,
        ): JSONObject? {
            val songId = audioState.optString("currentSongId", "")
            if (songId.isEmpty() || songId.startsWith("radio:")) return null

            val contextQueue = audioState.optJSONObject("contextQueue") ?: JSONObject()
            val snapshot = JSONObject()
            snapshot.put("sessionId", sessionId)
            snapshot.put("logicalPlaybackSessionId", sessionId)
            snapshot.put("mediaKind", "song")
            snapshot.put("songId", songId)
            snapshot.put("progressSeconds", audioState.optDouble("currentTime", 0.0).coerceAtLeast(0.0))
            snapshot.put("durationSeconds", audioState.optDouble("duration", 0.0).coerceAtLeast(0.0))
            snapshot.put("isPlaying", audioState.optBoolean("isPlaying", false))
            snapshot.put("sampledAt", sampledAtSeconds)
            snapshot.put("contextQueue", songIds(contextQueue.optJSONArray("songs")))
            snapshot.put("contextIndex", contextQueue.optInt("currentIndex", 0).coerceAtLeast(0))
            snapshot.put("sourceId", encodeSourceId(contextQueue.optJSONObject("sourceId")))
            snapshot.put("sourceName", contextQueue.optStringOrNull("sourceName"))
            snapshot.put("userQueue", songIds(audioState.optJSONArray("userQueue")))
            snapshot.put("inUserQueue", audioState.optBoolean("isInUserQueue", false))
            snapshot.put("restorePrevious", songIds(audioState.optJSONArray("playedUserQueueHistory")))
            snapshot.put("shuffle", audioState.optBoolean("isShuffleActive", false))
            snapshot.put("repeat", audioState.optString("loopState", "off"))
            snapshot.put("volume", volume ?: JSONObject.NULL)
            snapshot.put("accumulatedPlaySeconds", 0.0)
            snapshot.put("historyWritten", false)
            snapshot.put("nowPlayingSent", false)
            snapshot.put("scrobbleSent", false)
            return snapshot
        }

        private fun songIds(songs: JSONArray?): JSONArray {
            val ids = JSONArray()
            if (songs == null) return ids
            for (i in 0 until songs.length()) {
                val id = songs.optJSONObject(i)?.optString("id", "") ?: ""
                if (id.isNotEmpty()) ids.put(id)
            }
            return ids
        }

        private fun encodeSourceId(sourceId: JSONObject?): Any {
            if (sourceId == null) return JSONObject.NULL
            val type = sourceId.optString("type", "")
            val id = sourceId.optString("id", "")
            if (type.isEmpty() || id.isEmpty()) return JSONObject.NULL
            return "$type:$id"
        }

        private fun JSONObject.optStringOrNull(name: String): Any {
            if (isNull(name)) return JSONObject.NULL
            val value = optString(name, "")
            return if (value.isEmpty()) JSONObject.NULL else value
        }

        /// Parse a JSON object string, returning null on failure so callers
        /// can reject the plugin call with a structured error instead of
        /// crashing the bridge with an uncaught JSONException.
        internal fun parseJsonObject(json: String): JSONObject? =
            try {
                JSONObject(json)
            } catch (e: org.json.JSONException) {
                null
            }

        /// Append the one-time WebSocket ticket as a URL-encoded query
        /// parameter so tickets containing &/=/?/# do not break the URL.
        /// Uses URLEncoder (pure Java) rather than android.net.Uri.encode,
        /// which is not available in unit tests.
        internal fun buildTicketUrl(wsUrl: String, ticket: String): String {
            val base = wsUrl
            val separator = if (base.contains("?")) "&" else "?"
            val encoded = java.net.URLEncoder.encode(ticket, "UTF-8")
            return base + separator + "ticket=" + encoded
        }

        /// §9.1: extract the `seq` field from an envelope JSON object.
        /// Returns null when absent or not a number.
        internal fun extractSeq(env: JSONObject): Long? {
            val seq = env.opt("seq") ?: return null
            return when (seq) {
                is Number -> seq.toLong()
                is String -> seq.toLongOrNull()
                else -> null
            }
        }

        /// §9.1: extract the `messageId` field from an envelope JSON object.
        /// Returns null when absent.
        internal fun extractMessageId(env: JSONObject): String? {
            val id = env.opt("messageId") ?: return null
            return if (id is String) id else null
        }

        /// §9.1: extract the `type` field from an envelope JSON object.
        /// Returns null when absent.
        internal fun extractType(env: JSONObject): String? {
            val t = env.opt("type") ?: return null
            return if (t is String) t else null
        }

        /// Called by PlaybackService.onStartCommand through AppServices when
        /// the foreground service is (re)started.
        @JvmStatic
        fun attachToActiveForegroundService(): Boolean =
            AppServices.current()?.coordinationService()?.attachToForegroundService() ?: false

        /// Called by PlaybackService when the service is torn down.
        @JvmStatic
        fun detachActiveForegroundService() {
            AppServices.current()?.coordinationService()?.detachFromForegroundService()
        }

        @JvmStatic
        fun sendCommandFromActive(
            targetDeviceId: String,
            expectedGeneration: Int?,
            command: JSONObject
        ): Boolean {
            return AppServices.current()?.coordinationService()?.sendCommand(
                targetDeviceId,
                expectedGeneration,
                command,
            ) ?: false
        }

        @JvmStatic
        fun publishSnapshotFromActiveAudioState(): Boolean {
            return AppServices.current()?.coordinationService()
                ?.publishNativePlaybackSnapshot() ?: false
        }
    }

    /// Holds the live coordination socket plus its heartbeat scheduling and
    /// the owning OkHttpClient. This is what the PlaybackService keeps a
    /// reference to so the OS treats the socket as part of the foreground
    /// service's work (design §2.1.8). The plugin remains the single source of
    /// truth for connect/disconnect/reconnect; the holder is a passive
    /// reference used only for lifetime association.
    internal class CoordinationConnection(
        @get:JvmName("client") val client: OkHttpClient,
        @get:JvmName("webSocket") val webSocket: WebSocket,
        @get:JvmName("heartbeatHandler") val heartbeatHandler: Handler?,
        @get:JvmName("heartbeatRunnable") val heartbeatRunnable: Runnable,
    )

    private var webSocket: WebSocket? = null
    private var client: OkHttpClient? = null
    private var deviceId: String? = null
    private var capabilities: Int = 0
    private var protocolVersion: Int = 1
    private var isConnecting: Boolean = false
    private var reconnectAttempts: Int = 0
    private val sessionPreferences by lazy { runCatching { context.getSharedPreferences("native_coordination_session", 0) }.getOrNull() }
    private var nativeSessionId: String = runCatching { sessionPreferences?.getString("session", null) }.getOrNull() ?: java.util.UUID.randomUUID().toString()
    private var nativeGeneration: Int = runCatching { sessionPreferences?.getInt("generation", 1) }.getOrNull() ?: 1
    @Volatile private var handoffPreparing = false
    private var nativeSnapshotRevision: Int = runCatching { sessionPreferences?.getInt("revision", 0) }.getOrNull() ?: 0
    private val deviceGenerations = mutableMapOf<String, Int>()
    private val deviceSnapshotRevisions = mutableMapOf<String, Int>()
    private var activeRemoteControlTargetDeviceId: String? = null
    private var pendingNativeHandoffSourceDeviceId: String? = null
    private var pendingNativeHandoffRetryWaitingForSnapshot: Boolean = false
    private var pendingNativeHandoffRetryCount: Int = 0
    private data class PendingNativeCommand(
        val targetDeviceId: String,
        val commandJson: String,
        val attemptedStaleRetry: Boolean,
    )
    private val pendingNativeCommands = mutableMapOf<String, PendingNativeCommand>()
    /// §9.1 dedup cache for incoming envelopes.
    internal var dedupCache: CoordinationDedup = CoordinationDedup(DEDUP_CACHE_MAX)
        private set
    /// §9.2 sequence tracker — highest server seq processed.
    internal var seqTracker: CoordinationSeqTracker = CoordinationSeqTracker()
        private set
    /// True after an explicit `disconnect()` (or service teardown). Prevents
    /// the auto-reconnect path from firing for a user-initiated close.
    private var manualDisconnect: Boolean = false
    /// Set to true while a foreground service is registered, so a connect()
    /// that happens while the service is running attaches the new socket.
    @Volatile
    private var foregroundServiceActive: Boolean = false
    /// Main-thread Handler used for heartbeat/reconnect scheduling. Lazily
    /// created so the plugin can be instantiated in unit tests without an
    /// Android Looper (design §2.1.8 lifecycle tests). When `null` (tests),
    /// scheduling calls are no-ops.
    private var mainHandler: Handler? = null
        get() {
            if (field == null) {
                try {
                    field = Handler(Looper.getMainLooper())
                } catch (_: Throwable) {
                    // Unit tests run without an Android Looper; leave null.
                }
            }
            return field
        }
    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            sendEnvelope(buildHeartbeatEnvelope(protocolVersion))
            mainHandler?.postDelayed(this, HEARTBEAT_INTERVAL_SECONDS * 1000)
        }
    }
    private val reconnectRunnable = Runnable {
        // §6.3: tickets are one-time and expire in 30s, so the native layer
        // cannot self-reconnect. Ask the native controller to fetch a fresh ticket and
        // call connect() again.
        reconnectAttempts += 1
        notifyReconnectNeeded(reconnectAttempts)
    }
    private val snapshotHeartbeatRunnable = object : Runnable {
        override fun run() {
            publishNativePlaybackSnapshotIfPlaying()
            mainHandler?.postDelayed(this, SNAPSHOT_HEARTBEAT_MS)
        }
    }

    /// Reference held while the PlaybackService foreground service is
    /// active. Null means the plugin owns the socket itself (no service).
    /// This is package-visible so tests and the service can inspect it.
    @Volatile
    internal var foregroundServiceConnection: CoordinationConnection? = null
        private set

    /// Design §6.3: coordination tokens are encrypted with a Keystore-backed
    /// AES-GCM key. Falls back to null when unavailable (e.g. unit tests).
    private val tokenStore: CoordinationTokenStore? by lazy {
        try {
            CoordinationTokenStore(context)
        } catch (e: Exception) {
            Log.e(TAG, "CoordinationTokenStore unavailable", e)
            null
        }
    }

    internal fun loadTokens(): CoordinationTokenBundle? = tokenStore?.retrieve()
    internal fun storeTokens(bundle: CoordinationTokenBundle) { (tokenStore ?: error("Secure storage unavailable")).store(bundle) }
    fun clearTokens() { tokenStore?.delete() }
    fun storeConfig(serverUrl: String, identityUrl: String) {
        context.getSharedPreferences(PREFS_NAME, 0).edit().putString(KEY_SERVER_URL, serverUrl).putString(KEY_IDENTITY_URL, identityUrl).apply()
    }
    fun loadConfig(): Pair<String, String>? {
        val prefs = context.getSharedPreferences(PREFS_NAME, 0)
        return prefs.getString(KEY_SERVER_URL, null)?.let { server -> server to (prefs.getString(KEY_IDENTITY_URL, null) ?: return null) }
    }
    suspend fun request(url: String, method: String = "GET", body: String? = null, headers: Map<String, String> = emptyMap()): CoordinationHttpResponse = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(url)
        headers.forEach { (key, value) -> builder.header(key, value) }
        val requestBody = body?.toRequestBody("application/json; charset=utf-8".toMediaType())
        builder.method(method, if (method in setOf("GET", "HEAD")) null else requestBody ?: ByteArray(0).toRequestBody())
        OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build().newCall(builder.build()).execute().use { response -> CoordinationHttpResponse(response.code, response.message, response.body?.string().orEmpty()) }
    }
    fun disconnect() { manualDisconnect = true; disconnectInternal(); notifyState("disconnected") }
    fun connectionState(): JSONObject = JSONObject().put("state", _state.value).put("deviceId", deviceId ?: JSONObject.NULL)
    fun submitEnvelope(envelope: JSONObject) {
        envelope.put("version", protocolVersion)
        if (!envelope.has("messageId")) envelope.put("messageId", java.util.UUID.randomUUID().toString())
        sendEnvelope(envelope)
    }
    fun sendActiveCommand(command: JSONObject): Boolean = activeRemoteControlTargetDeviceId?.let { sendCommand(it, deviceGenerations[it], command) } ?: false
    fun beginControl(target: String) { activeRemoteControlTargetDeviceId = target; submitEnvelope(JSONObject().put("type", "control_session_begin").put("targetDeviceId", target)); requestSnapshots() }
    fun endControl() { activeRemoteControlTargetDeviceId = null; audioService()?.clearRemotePlaybackProjection(); submitEnvelope(JSONObject().put("type", "control_session_end")) }
    fun handoffFromCache(source: String): Boolean {
        if (!sendHandoffCandidateRequestFromCache(source)) return false
        pendingNativeHandoffSourceDeviceId = source
        pendingNativeHandoffRetryWaitingForSnapshot = false
        pendingNativeHandoffRetryCount = 0
        return true
    }
    fun requestPeerSnapshots() = requestSnapshots()

    fun connect(wsUrl: String, ticket: String, devId: String, capabilities: Int = 127, protocolVersion: Int = 1, lastSeq: Long = 0) {
        this.deviceId = devId
        this.capabilities = capabilities
        this.protocolVersion = protocolVersion
        // §9.2: the client submits the highest seq it has processed so the
        // server can skip already-delivered messages. When the caller omits
        // lastSeq (first-ever connect), default to 0.
        val lastSeqValue = lastSeq
        this.seqTracker = CoordinationSeqTracker().apply { observe(lastSeqValue) }

        // Lifecycle correctness (§2.1.8): if the socket is already open, do
        // not create a second one when the app returns to the foreground or
        // the service re-attaches. Reuse the existing connection.
        val current = webSocket
        if (current != null && !isConnecting) {
            // Already connected. Re-attach to the service if it is active so
            // the foreground service regains its reference.
            if (foregroundServiceActive) attachToForegroundService()
            return
        }

        manualDisconnect = false
        disconnectInternal()
        // The dedup cache is per-connection; clear it so a reconnect does
        // not falsely skip messages from the new connection.
        dedupCache.clear()

        val urlWithTicket = buildTicketUrl(wsUrl, ticket)
        this.client = OkHttpClient.Builder()
            .pingInterval(PING_INTERVAL_SECONDS, TimeUnit.SECONDS)
            .build()
        val request = Request.Builder().url(urlWithTicket).build()
        this.webSocket = this.client?.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = dispatchOnMain {
                if (this@NativeCoordinationService.webSocket !== webSocket) return@dispatchOnMain
                isConnecting = false
                reconnectAttempts = 0
                sendEnvelope(
                    buildHelloEnvelope(
                        protocolVersion = protocolVersion,
                        capabilities = capabilities,
                        deviceId = devId,
                        ticket = ticket,
                        lastSeq = lastSeqValue,
                    ),
                )
                startHeartbeat()
                startSnapshotHeartbeat()
                // If the foreground service is running, attach now so the
                // fresh socket is associated with it for background survival.
                if (foregroundServiceActive) attachToForegroundService()
                notifyState("connected")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (this@NativeCoordinationService.webSocket !== webSocket) return
                mainHandler?.post { if (this@NativeCoordinationService.webSocket === webSocket) dispatchEnvelope(text) }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = dispatchOnMain {
                if (this@NativeCoordinationService.webSocket !== webSocket) return@dispatchOnMain
                this@NativeCoordinationService.webSocket = null
                client = null
                isConnecting = false
                if (handoffPreparing) {
                    handoffPreparing = false
                    audioService()?.rollbackHandoff()
                }
                stopHeartbeat()
                stopSnapshotHeartbeat()
                foregroundServiceConnection = null
                notifyState("disconnected")
                if (!manualDisconnect) scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = dispatchOnMain {
                if (this@NativeCoordinationService.webSocket !== webSocket) return@dispatchOnMain
                Log.e(TAG, "WS failure", t)
                this@NativeCoordinationService.webSocket = null
                client = null
                isConnecting = false
                if (handoffPreparing) {
                    handoffPreparing = false
                    audioService()?.rollbackHandoff()
                }
                stopHeartbeat()
                stopSnapshotHeartbeat()
                foregroundServiceConnection = null
                notifyState("error")
                if (!manualDisconnect) scheduleReconnect()
            }
        })
        this.isConnecting = true
        notifyState("connecting")
    }

    private fun persistSession() {
        sessionPreferences?.edit()?.putString("session", nativeSessionId)?.putInt("generation", nativeGeneration)?.putInt("revision", nativeSnapshotRevision)?.apply()
    }
    private fun dispatchOnMain(block: () -> Unit) { mainHandler?.post { block() } ?: block() }
    private fun requestSnapshots() {
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "request_snapshots")
        sendEnvelope(env)
    }

    private fun sendHandoffCandidateRequestFromCache(sourceDeviceId: String): Boolean {
        val generation = deviceGenerations[sourceDeviceId] ?: return false
        val snapshotRevision = deviceSnapshotRevisions[sourceDeviceId] ?: return false
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "handoff_candidate_request")
        env.put("sourceDeviceId", sourceDeviceId)
        env.put("expectedGeneration", generation)
        env.put("expectedSnapshotRevision", snapshotRevision)
        sendEnvelope(env)
        return true
    }

    private fun disconnectInternal() {
        if (handoffPreparing) {
            handoffPreparing = false
            audioService()?.rollbackHandoff()
        }
        stopHeartbeat()
        stopSnapshotHeartbeat()
        mainHandler?.removeCallbacks(reconnectRunnable)
        reconnectAttempts = 0
        webSocket?.close(1000, "disconnect")
        webSocket = null
        client = null
        isConnecting = false
        // Drop the foreground-service association: there is nothing left to
        // keep alive. The service will call detachFromForegroundService() on
        // its own teardown, but we clear defensively in case disconnect runs
        // first.
        foregroundServiceConnection = null
        // §9.1/§9.2: clear the dedup cache and reset the seq tracker so a
        // reconnect starts clean. The next `connect()` call supplies the
        // lastSeq option again.
        dedupCache.clear()
        seqTracker.reset()
    }

    // MARK: - Foreground service coordination (design §2.1.8, §5.2)

    /// Attach the active coordination connection to the PlaybackService
    /// foreground service so the OS treats the WebSocket as part of the
    /// foreground service's work and does not suspend it on backgrounding.
    ///
    /// Idempotent: a second attach while already attached is a no-op (no
    /// duplicate socket is created). If no connection is currently active
    /// this is a no-op and the next `connect()` will attach automatically via
    /// `attachIfActive`. Returns true if a connection was attached (or was
    /// already attached), false if no connection is active.
    @Synchronized
    override fun attachToForegroundService(): Boolean {
        foregroundServiceActive = true
        val ws = webSocket
        val okClient = client
        if (ws == null || okClient == null) {
            // No live connection yet — flag that the service is running so the
            // next connect()/onOpen attaches automatically.
            return false
        }
        if (foregroundServiceConnection != null) {
            // Already attached — reuse, never create a second socket.
            return true
        }
        foregroundServiceConnection = CoordinationConnection(
            client = okClient,
            webSocket = ws,
            heartbeatHandler = mainHandler,
            heartbeatRunnable = heartbeatRunnable,
        )
        logDebug("Coordination connection attached to foreground service")
        return true
    }

    /// Detach the coordination connection from the PlaybackService. Called
    /// by the service when it is torn down (onTaskRemoved that stops playback,
    /// or onDestroy). Safe to call when nothing is attached (no-op).
    ///
    /// Per §2.1.8 graceful-degradation requirement, detaching does NOT close
    /// the socket here: the socket may still be alive and the plugin keeps
    /// running it in plugin-owned mode. The service only releases its
    /// reference so its own teardown does not yank the socket. The socket is
    /// closed by `disconnectInternal()` / WebSocket callbacks as usual.
    @Synchronized
    override fun detachFromForegroundService() {
        foregroundServiceActive = false
        if (foregroundServiceConnection == null) return
        foregroundServiceConnection = null
        logDebug("Coordination connection detached from foreground service")
    }

    /// Whether the coordination connection is currently attached to a
    /// foreground service. Exposed for tests and observability.
    internal fun isAttachedToForegroundService(): Boolean =
        foregroundServiceConnection != null

    // MARK: - Test-only helpers (design §2.1.8 lifecycle tests)

    /// Test-only: inject a fake client/webSocket pair so lifecycle helpers can
    /// be exercised without a live network. Returns true if the fake state was
    /// accepted. Not annotated `@VisibleForTesting` to avoid the extra
    /// androidx.annotation dependency in unit tests.
    internal fun setConnectionForTesting(client: OkHttpClient?, webSocket: WebSocket?) {
        this.client = client
        this.webSocket = webSocket
    }

    /// Test-only: read the plugin-owned socket for assertions.
    internal fun connectionForTesting(): Pair<OkHttpClient?, WebSocket?> = Pair(client, webSocket)

    /// Test-only: mark the foreground service as active so connect()/onOpen
    /// attach automatically, without requiring a real PlaybackService.
    internal fun setForegroundServiceActiveForTesting(active: Boolean) {
        this.foregroundServiceActive = active
    }

    /// Test-only: read the manualDisconnect flag for assertions.
    internal fun isManualDisconnectForTesting(): Boolean = manualDisconnect

    private fun startHeartbeat() {
        val handler = mainHandler ?: return
        handler.removeCallbacks(heartbeatRunnable)
        handler.postDelayed(heartbeatRunnable, HEARTBEAT_INTERVAL_SECONDS * 1000)
    }

    private fun stopHeartbeat() {
        mainHandler?.removeCallbacks(heartbeatRunnable)
    }

    private fun startSnapshotHeartbeat() {
        val handler = mainHandler ?: return
        handler.removeCallbacks(snapshotHeartbeatRunnable)
        handler.postDelayed(snapshotHeartbeatRunnable, SNAPSHOT_HEARTBEAT_MS)
    }

    private fun stopSnapshotHeartbeat() {
        mainHandler?.removeCallbacks(snapshotHeartbeatRunnable)
    }

    private fun sendEnvelope(env: JSONObject) {
        webSocket?.send(env.toString())
    }

    private fun audioService() = AppServices.current()?.audioService()

    private fun JSONObject.toAudioRemotePlaybackSnapshot(
        targetDeviceId: String,
        expectedGeneration: Int,
    ): AudioRemotePlaybackSnapshot = AudioRemotePlaybackSnapshot(
        songId = optString("songId", "").takeIf { it.isNotEmpty() },
        sourceName = optString("sourceName", "").takeIf { it.isNotEmpty() },
        isPlaying = optBoolean("isPlaying", false),
        progressSeconds = optDouble("progressSeconds", 0.0),
        durationSeconds = optDouble("durationSeconds", 0.0),
        isShuffleActive = optBoolean("shuffle", false),
        repeatMode = optString("repeat", "off"),
        volume = if (has("volume") && !isNull("volume")) optDouble("volume") else null,
        targetDeviceId = targetDeviceId,
        expectedGeneration = expectedGeneration,
    )

    override fun publishNativePlaybackSnapshot(): Boolean =
        publishNativePlaybackSnapshotInternal()

    private fun publishNativePlaybackSnapshotIfPlaying(): Boolean =
        publishNativePlaybackSnapshotInternal(onlyWhenPlaying = true)

    private fun publishNativePlaybackSnapshotInternal(onlyWhenPlaying: Boolean = false): Boolean {
        if (webSocket == null || handoffPreparing) return false
        val audioState = AppServices.current()?.audioService()?.getFullState() ?: return false
        if (onlyWhenPlaying && !audioState.optBoolean("isPlaying", false)) {
            return false
        }
        val snapshot = buildPlaybackSnapshot(
            sessionId = nativeSessionId,
            audioState = audioState,
            sampledAtSeconds = System.currentTimeMillis() / 1000.0,
        ) ?: return false

        nativeSnapshotRevision += 1
        persistSession()
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "snapshot")
        env.put("sessionId", nativeSessionId)
        env.put("generation", nativeGeneration)
        env.put("snapshotRevision", nativeSnapshotRevision)
        env.put("snapshot", snapshot)
        sendEnvelope(env)
        return true
    }

    private fun sendCommandFromNative(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: JSONObject
    ): Boolean {
        if (webSocket == null) return false
        val generation = expectedGeneration ?: deviceGenerations[targetDeviceId] ?: return false

        val messageId = java.util.UUID.randomUUID().toString()
        pendingNativeCommands[messageId] = PendingNativeCommand(
            targetDeviceId,
            command.toString(),
            attemptedStaleRetry = false,
        )
        sendCommandEnvelope(messageId, targetDeviceId, generation, command)
        mainHandler?.postDelayed({ if (pendingNativeCommands.remove(messageId) != null) emit("coordinationEvent", JSONObject().put("envelopeJson", "{\"type\":\"error\",\"reason\":\"Remote command timed out\"}")) }, 15000)
        return true
    }

    override fun sendCommand(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: JSONObject,
    ): Boolean = sendCommandFromNative(targetDeviceId, expectedGeneration, command)

    private fun sendCommandEnvelope(
        messageId: String,
        targetDeviceId: String,
        expectedGeneration: Int,
        command: JSONObject,
    ) {
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", messageId)
        env.put("type", "command")
        env.put("targetDeviceId", targetDeviceId)
        env.put("expectedGeneration", expectedGeneration)
        env.put("command", command)
        sendEnvelope(env)
    }

    private fun handleNativeCommandAck(env: JSONObject): Boolean {
        val messageId = extractMessageId(env) ?: return false
        val pending = pendingNativeCommands[messageId] ?: return false
        val result = env.optJSONObject("result")
        val isStaleEpoch =
            result?.optString("status") == "error" &&
                result.optString("code") == "stale_epoch"
        pendingNativeCommands.remove(messageId)
        if (!isStaleEpoch || pending.attemptedStaleRetry) {
            if (result?.optString("status") == "error") emit("coordinationEvent", JSONObject().put("envelopeJson", JSONObject().put("type", "error").put("reason", result.optString("reason", result.optString("code", "Command failed"))).toString()))
            return true
        }

        val generation = deviceGenerations[pending.targetDeviceId] ?: return true
        val command = parseJsonObject(pending.commandJson) ?: return true
        val retryMessageId = java.util.UUID.randomUUID().toString()
        pendingNativeCommands[retryMessageId] = pending.copy(
            attemptedStaleRetry = true,
        )
        sendCommandEnvelope(
            retryMessageId,
            pending.targetDeviceId,
            generation,
            command,
        )
        return true
    }

    private fun dispatchEnvelope(json: String) {
        // Native routing is independent of the optional Capacitor event adapter.
        val parsed = parseJsonObject(json)
        if (parsed != null) {
            // §9.2: track the incoming seq on every envelope.
            seqTracker.observe(extractSeq(parsed))
            // §9.1: dedup command/snapshot_projection envelopes by messageId.
            val type = extractType(parsed)
            if (type == "prepare_relinquish" || type?.startsWith("handoff_") == true || type == "session_superseded") {
                logDebug("coordination: received $type")
            }
            if (type == "snapshot_projection") {
                val snapshotDeviceId = parsed.optString("deviceId", "")
                val generation = parsed.optInt("generation", 0)
                val snapshotRevision = parsed.optInt("snapshotRevision", 0)
                if (snapshotDeviceId.isNotEmpty() && generation > 0) {
                    deviceGenerations[snapshotDeviceId] = generation
                }
                if (snapshotDeviceId.isNotEmpty() && snapshotRevision > 0) {
                    deviceSnapshotRevisions[snapshotDeviceId] = snapshotRevision
                }
                if (
                    pendingNativeHandoffRetryWaitingForSnapshot &&
                    snapshotDeviceId == pendingNativeHandoffSourceDeviceId &&
                    sendHandoffCandidateRequestFromCache(snapshotDeviceId)
                ) {
                    pendingNativeHandoffRetryWaitingForSnapshot = false
                }
                if (snapshotDeviceId == activeRemoteControlTargetDeviceId) {
                    val snapshot = parsed.optJSONObject("snapshot")
                    if (snapshot == null || !parsed.optBoolean("isOnline", true)) {
                        audioService()?.clearRemotePlaybackProjection()
                    } else {
                        snapshot.toAudioRemotePlaybackSnapshot(
                            snapshotDeviceId,
                            generation,
                        )?.let { audioService()?.applyRemotePlaybackSnapshot(it) }
                    }
                }
            }
            if (type == "command" || type == "snapshot_projection") {
                val id = extractMessageId(parsed)
                if (id != null) {
                    if (dedupCache.has(id)) {
                        // Duplicate — skip re-dispatching (debug-level only).
                        logDebug("coordination: dedup skipped envelope $id")
                        return
                    }
                    dedupCache.mark(id)
                }
            }
            // §9.1: native-origin commands consume their ack entirely in the
            // native layer. Only JS-origin commands are bridged back so the
            // WebView facade can resolve its pending sendCommand() promise.
            if (type == "command_ack") {
                if (!handleNativeCommandAck(parsed)) {
                    val messageId = extractMessageId(parsed) ?: ""
                    val result = parsed.opt("result")?.toString() ?: "{}"
                    val ret = JSONObject()
                    ret.put("messageId", messageId)
                    ret.put("resultJson", result)
                    emit("coordinationAck", ret)
                }
            }
            if (type == "command") {
                val command = parsed.optJSONObject("command")
                val messageId = extractMessageId(parsed)
                commandScope.launch {
                    val result = if (command == null) AudioCommandResult.Failure("bad_message", "Missing command") else audioService()?.executeRemoteCommand(command) ?: AudioCommandResult.Failure("not_ready", "Playback service unavailable")
                    val ack = when (result) {
                        AudioCommandResult.Success -> JSONObject().put("status", "ok")
                        is AudioCommandResult.Failure -> JSONObject().put("status", "error").put("code", result.code).put("reason", result.message)
                    }
                    if (messageId != null) sendEnvelope(buildCommandAckEnvelope(protocolVersion, messageId, ack))
                }
                return
            }
            if (type == "prepare_relinquish") {
                val transactionId = parsed.optString("transactionId", "")
                val audioState = audioService()?.pauseAndGetFullState()
                logDebug("coordination: relinquish captured=${audioState != null}")
                val snapshot = if (audioState != null) {
                    buildPlaybackSnapshot(
                        sessionId = nativeSessionId,
                        audioState = audioState,
                        sampledAtSeconds = System.currentTimeMillis() / 1000.0,
                    )
                } else {
                    null
                }
                if (transactionId.isNotEmpty() && snapshot != null) {
                    sendEnvelope(
                        buildRelinquishAckEnvelope(
                            protocolVersion,
                            transactionId,
                            snapshot,
                        ),
                    )
                    return
                }
                if (transactionId.isNotEmpty()) {
                    sendEnvelope(
                        buildHandoffFailedEnvelope(
                            protocolVersion,
                            transactionId,
                            "source_pause_timeout",
                        ),
                    )
                    return
                }
            }
            if (type == "handoff_candidate") {
                handoffPreparing = true
                val connection = webSocket
                val snapshot = parsed.optJSONObject("snapshot")
                val transactionId = parsed.optString("transactionId", "")
                val sourceDeviceId = parsed.optString("sourceDeviceId", "")
                val sessionId = parsed.optString("sessionId", "")
                val accepted = if (
                    snapshot != null &&
                    transactionId.isNotEmpty() &&
                    sourceDeviceId.isNotEmpty() &&
                    sessionId.isNotEmpty()
                ) {
                    val service = audioService()
                    if (service == null) {
                        false
                    } else {
                        service.prepareHandoff(
                            snapshot,
                            autoplay = false,
                        ) { prepared ->
                            if (webSocket === connection && handoffPreparing) {
                                if (prepared) {
                                    sendEnvelope(
                                        buildTargetReadyEnvelope(
                                            protocolVersion,
                                            transactionId,
                                            parsed.optInt("generation", 0),
                                            parsed.optInt("snapshotRevision", 0),
                                            sourceDeviceId,
                                            sessionId,
                                        ),
                                    )
                                } else {
                                    handoffPreparing = false
                                    audioService()?.rollbackHandoff()
                                    sendEnvelope(
                                        buildHandoffFailedEnvelope(
                                            protocolVersion,
                                            transactionId,
                                            "unsupported_media",
                                        ),
                                    )
                                }
                            }
                        }
                        true
                    }
                } else {
                    false
                }
                if (!accepted && transactionId.isNotEmpty()) {
                    handoffPreparing = false
                    sendEnvelope(
                        buildHandoffFailedEnvelope(
                            protocolVersion,
                            transactionId,
                            "unsupported_media",
                        ),
                    )
                }
                return
            }
            if (type == "handoff_committed") {
                pendingNativeHandoffSourceDeviceId = null
                pendingNativeHandoffRetryWaitingForSnapshot = false
                pendingNativeHandoffRetryCount = 0
                val snapshot = parsed.optJSONObject("snapshot")
                if (snapshot != null) {
                    nativeSessionId = snapshot.optString("sessionId", nativeSessionId)
                    nativeGeneration = parsed.optInt("newGeneration", nativeGeneration)
                    nativeSnapshotRevision = 0
                    persistSession()
                }
                val accepted = if (snapshot == null) {
                    false
                } else {
                    val service = audioService()
                    if (service == null) {
                        false
                    } else {
                        service.prepareHandoff(
                            snapshot,
                            autoplay = true,
                        ) { prepared ->
                            handoffPreparing = false
                            if (prepared) {
                                publishNativePlaybackSnapshot()
                                emit("coordinationEvent", JSONObject().put("envelopeJson", json))
                            } else {
                                audioService()?.rollbackHandoff()
                                emit("coordinationEvent", JSONObject().put("envelopeJson", buildHandoffFailedEnvelope(protocolVersion, parsed.optString("transactionId"), "unsupported_media").toString()))
                            }
                        }
                        true
                    }
                }
                if (accepted) {
                    return
                }
            }
            if (type == "handoff_failed") {
                handoffPreparing = false
                audioService()?.rollbackHandoff()
                pendingNativeHandoffSourceDeviceId = null
                pendingNativeHandoffRetryWaitingForSnapshot = false
                pendingNativeHandoffRetryCount = 0
            }
            if (type == "session_superseded") {
                nativeSessionId = java.util.UUID.randomUUID().toString()
                nativeGeneration = 1
                nativeSnapshotRevision = 0
                    persistSession()
                audioService()?.executeRemoteControlCommand(
                    JSONObject().put("type", "pause"),
                )
                return
            }
        }
        emit("coordinationEvent", JSONObject().put("envelopeJson", json))
    }

    private fun scheduleReconnect() {
        // §13: exponential backoff with a cap. Tickets expire in 30s so the
        // native layer only emits the request; the controller performs the
        // actual reconnect after refreshing the ticket.
        val attempt = (reconnectAttempts + 1).coerceAtMost(MAX_RECONNECT_ATTEMPTS)
        val delayMs = (BASE_RECONNECT_DELAY_MS * (1L shl (attempt - 1)))
            .coerceAtMost(MAX_RECONNECT_DELAY_MS)
        notifyState("reconnecting")
        mainHandler?.postDelayed(reconnectRunnable, delayMs)
    }

    private fun notifyReconnectNeeded(attempt: Int) {
        val ret = JSONObject()
        ret.put("attempt", attempt)
        emit("coordinationReconnectNeeded", ret)
    }

    private fun notifyState(state: String) {
        val ret = JSONObject()
        ret.put("state", state)
        ret.put("deviceId", deviceId ?: JSONObject.NULL)
        emit("coordinationStateChange", ret)
    }

    /// Wraps Log.d so unit tests (which run without android.util.Log mocked)
    /// do not crash on the stubbed Android static. Non-logging failures here
    /// are swallowed to keep the lifecycle path side-effect-free.
    private fun logDebug(message: String) {
        try {
            Log.d(TAG, message)
        } catch (_: Throwable) {
            // android.util.Log not mocked in unit tests.
        }
    }
}
