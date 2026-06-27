package github.realtvop.aonsoku.plugins.coordination

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import github.realtvop.aonsoku.plugins.audio.AudioPlugin
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

/// Native coordination plugin for Android — maintains a background WebSocket
/// connection to the coordination server, bridging remote commands and
/// handoff events to the native queue controller (design §8, §9, §10, §11).
///
/// Background lifecycle (design §2.1.8, §5.2): A Capacitor plugin is tied to
/// the Bridge activity lifecycle, so a plain plugin-owned WebSocket is
/// suspended by the OS when the app is backgrounded. To keep the coordination
/// presence alive while audio plays in the background, the active
/// CoordinationConnection is attached to the PlaybackService foreground
/// service (see `attachToForegroundService` / `detachFromForegroundService`).
/// When the service is active it holds a reference to the connection so the OS
/// treats the socket as part of the foreground service's work. The plugin
/// retains ownership of the connect/disconnect/heartbeat/reconnect logic; the
/// service only holds the reference and signals detach on teardown. If the
/// foreground service is not running, the plugin falls back to its own
/// plugin-owned socket, which degrades gracefully in the background: the
/// heartbeat is stopped, `disconnected` is emitted via
/// `coordinationStateChange`, and the next foreground entry triggers
/// `coordinationReconnectNeeded`.
///
/// Multi-stack consistency: the plugin receives the same RemoteCommand types
/// as the Web/Electron observer and dispatches them through the native audio
/// plugin's queue engine. The WebView-side CoordinationManager delegates to
/// this plugin when running on capacitor-android.
@CapacitorPlugin(name = "AonsokuNativeCoordination")
class AonsokuNativeCoordinationPlugin : Plugin() {

    companion object {
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

        internal fun buildPlaybackSnapshot(
            sessionId: String,
            audioState: JSONObject,
            sampledAtSeconds: Double,
            volume: Double? = null,
        ): JSONObject? {
            val songId = audioState.optString("currentSongId", "")
            if (songId.isEmpty()) return null

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

        /// Holds the currently-loaded plugin instance so the PlaybackService
        /// (which does not have access to the Capacitor Bridge) can reach the
        /// coordination plugin to attach/detach the socket for background
        /// survival (design §2.1.8). Set in `load()`, cleared in
        /// `handleOnDestroy()`.
        @Volatile
        internal var activeInstance: AonsokuNativeCoordinationPlugin? = null
            private set

        /// Called by PlaybackService.onStartCommand when the foreground service
        /// is (re)started. Idempotent. No-op if the plugin is not loaded.
        @JvmStatic
        fun attachToActiveForegroundService(): Boolean =
            activeInstance?.attachToForegroundService() ?: false

        /// Called by PlaybackService when the service is torn down
        /// (onTaskRemoved that stops playback, or onDestroy). No-op if the
        /// plugin is not loaded or nothing is attached.
        @JvmStatic
        fun detachActiveForegroundService() {
            activeInstance?.detachFromForegroundService()
        }

        @JvmStatic
        fun sendCommandFromActive(
            targetDeviceId: String,
            expectedGeneration: Int,
            command: JSONObject
        ): Boolean {
            return activeInstance
                ?.sendCommandFromNative(targetDeviceId, expectedGeneration, command)
                ?: false
        }

        @JvmStatic
        fun publishSnapshotFromActiveAudioState(): Boolean {
            return activeInstance?.publishNativePlaybackSnapshot() ?: false
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
    private var nativeSessionId: String = java.util.UUID.randomUUID().toString()
    private var nativeGeneration: Int = 1
    private var nativeSnapshotRevision: Int = 0
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
        // cannot self-reconnect. Ask the WebView to fetch a fresh ticket and
        // call connect() again.
        reconnectAttempts += 1
        notifyReconnectNeeded(reconnectAttempts)
    }
    private val snapshotHeartbeatRunnable = object : Runnable {
        override fun run() {
            publishNativePlaybackSnapshot(onlyWhenPlaying = true)
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

    override fun load() {
        super.load()
        activeInstance = this
    }

    override fun handleOnDestroy() {
        // Drop the foreground-service association before tearing down so the
        // service does not keep a dangling reference. The socket itself is
        // closed by disconnectInternal() when the WebView asks.
        detachFromForegroundService()
        manualDisconnect = true
        disconnectInternal()
        if (activeInstance === this) {
            activeInstance = null
        }
        super.handleOnDestroy()
    }

    @PluginMethod
    fun storeTokens(call: PluginCall) {
        try {
            val accessToken = call.getString("accessToken") ?: return call.reject("missing accessToken")
            val refreshToken = call.getString("refreshToken") ?: return call.reject("missing refreshToken")
            val deviceId = call.getString("deviceId") ?: return call.reject("missing deviceId")
            val accountId = call.getString("accountId") ?: return call.reject("missing accountId")
            val historyLimit = call.getInt("historyLimit", 100) ?: 100

            val store = tokenStore ?: return call.reject("secure storage unavailable")
            store.store(
                CoordinationTokenBundle(
                    accessToken = accessToken,
                    refreshToken = refreshToken,
                    deviceId = deviceId,
                    accountId = accountId,
                    historyLimit = historyLimit,
                ),
            )
            call.resolve()
        } catch (e: Exception) {
            call.reject("storeTokens failed: ${e.message}")
        }
    }

    @PluginMethod
    fun loadTokens(call: PluginCall) {
        val bundle = tokenStore?.retrieve() ?: return call.resolve()
        val ret = JSObject()
        ret.put("accessToken", bundle.accessToken)
        ret.put("refreshToken", bundle.refreshToken)
        ret.put("deviceId", bundle.deviceId)
        ret.put("accountId", bundle.accountId)
        ret.put("historyLimit", bundle.historyLimit)
        call.resolve(ret)
    }

    @PluginMethod
    fun clearTokens(call: PluginCall) {
        tokenStore?.delete()
        call.resolve()
    }

    @PluginMethod
    fun storeConfig(call: PluginCall) {
        val serverUrl = call.getString("serverUrl") ?: return call.reject("missing serverUrl")
        val identityUrl = call.getString("identityUrl") ?: return call.reject("missing identityUrl")
        context.getSharedPreferences(PREFS_NAME, 0).edit()
            .putString(KEY_SERVER_URL, serverUrl)
            .putString(KEY_IDENTITY_URL, identityUrl)
            .apply()
        call.resolve()
    }

    @PluginMethod
    fun loadConfig(call: PluginCall) {
        val prefs = context.getSharedPreferences(PREFS_NAME, 0)
        val serverUrl = prefs.getString(KEY_SERVER_URL, null)
        val identityUrl = prefs.getString(KEY_IDENTITY_URL, null)
        if (serverUrl == null || identityUrl == null) return call.resolve()
        val ret = JSObject()
        ret.put("serverUrl", serverUrl)
        ret.put("identityUrl", identityUrl)
        call.resolve(ret)
    }

    @PluginMethod
    fun request(call: PluginCall) {
        val url = call.getString("url") ?: return call.reject("missing url")
        val method = call.getString("method", "GET") ?: "GET"
        val body = call.getString("body")
        val headers = call.getObject("headers")

        Thread {
            try {
                val builder = Request.Builder().url(url)
                headers?.let {
                    val keys = it.keys()
                    while (keys.hasNext()) {
                        val key = keys.next()
                        val value = it.opt(key)
                        if (value != null && value != JSONObject.NULL) {
                            builder.header(key, value.toString())
                        }
                    }
                }

                val requestBody = body?.toRequestBody(
                    "application/json; charset=utf-8".toMediaType(),
                )
                val request = when (method.uppercase()) {
                    "GET" -> builder.get().build()
                    "HEAD" -> builder.head().build()
                    "DELETE" -> if (requestBody != null) {
                        builder.delete(requestBody).build()
                    } else {
                        builder.delete().build()
                    }
                    "POST", "PUT", "PATCH" -> builder
                        .method(
                            method.uppercase(),
                            requestBody ?: ByteArray(0).toRequestBody(),
                        )
                        .build()
                    else -> builder.method(method.uppercase(), requestBody).build()
                }

                OkHttpClient().newCall(request).execute().use { response ->
                    val ret = JSObject()
                    ret.put("status", response.code)
                    ret.put("statusText", response.message)
                    ret.put("body", response.body?.string() ?: "")
                    call.resolve(ret)
                }
            } catch (e: Exception) {
                call.reject("native coordination request failed: ${e.message}")
            }
        }.start()
    }

    @PluginMethod
    fun connect(call: PluginCall) {
        val wsUrl = call.getString("wsUrl") ?: return call.reject("missing wsUrl")
        val ticket = call.getString("ticket") ?: return call.reject("missing ticket")
        val devId = call.getString("deviceId") ?: return call.reject("missing deviceId")
        this.deviceId = devId
        this.capabilities = call.getInt("capabilities", 0) ?: 0
        this.protocolVersion = call.getInt("protocolVersion", 1) ?: 1
        // §9.2: the client submits the highest seq it has processed so the
        // server can skip already-delivered messages. When the caller omits
        // lastSeq (first-ever connect), default to 0.
        val lastSeqValue = call.getDouble("lastSeq", 0.0)?.toLong() ?: 0L
        this.seqTracker = CoordinationSeqTracker().apply { observe(lastSeqValue) }

        // Lifecycle correctness (§2.1.8): if the socket is already open, do
        // not create a second one when the app returns to the foreground or
        // the service re-attaches. Reuse the existing connection.
        val current = webSocket
        if (current != null && !isConnecting) {
            // Already connected. Re-attach to the service if it is active so
            // the foreground service regains its reference.
            if (foregroundServiceActive) attachToForegroundService()
            call.resolve()
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
            override fun onOpen(webSocket: WebSocket, response: Response) {
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
                dispatchEnvelope(text)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                isConnecting = false
                stopHeartbeat()
                stopSnapshotHeartbeat()
                foregroundServiceConnection = null
                notifyState("disconnected")
                if (!manualDisconnect) scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "WS failure", t)
                isConnecting = false
                stopHeartbeat()
                stopSnapshotHeartbeat()
                foregroundServiceConnection = null
                notifyState("error")
                if (!manualDisconnect) scheduleReconnect()
            }
        })
        this.isConnecting = true
        notifyState("connecting")
        call.resolve()
    }

    @PluginMethod
    fun disconnect(call: PluginCall) {
        manualDisconnect = true
        disconnectInternal()
        call.resolve()
    }

    @PluginMethod
    fun getState(call: PluginCall) {
        val state = when {
            webSocket == null -> "disconnected"
            isConnecting -> "connecting"
            else -> "connected"
        }
        val ret = JSObject()
        ret.put("state", state)
        ret.put("deviceId", deviceId ?: JSONObject.NULL)
        call.resolve(ret)
    }

    @PluginMethod
    fun publishSnapshot(call: PluginCall) {
        val snapshotJson = call.getString("snapshotJson") ?: return call.reject("missing snapshotJson")
        val parsed = parseJsonObject(snapshotJson) ?: return call.reject("invalid snapshotJson")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "snapshot")
        env.put("sessionId", call.getString("sessionId", ""))
        env.put("generation", call.getInt("generation", 0) ?: 0)
        env.put("snapshotRevision", call.getInt("snapshotRevision", 0) ?: 0)
        env.put("snapshot", parsed)
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun sendCommand(call: PluginCall) {
        val commandJson = call.getString("commandJson") ?: return call.reject("missing commandJson")
        val targetDeviceId = call.getString("targetDeviceId") ?: return call.reject("missing targetDeviceId")
        val parsed = parseJsonObject(commandJson) ?: return call.reject("invalid commandJson")
        // §9.1: the caller may supply a messageId to match the command to a
        // pending-ack promise. Fall back to a generated UUID.
        val messageId = call.getString("messageId") ?: java.util.UUID.randomUUID().toString()
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", messageId)
        env.put("type", "command")
        env.put("targetDeviceId", targetDeviceId)
        env.put("expectedGeneration", call.getInt("expectedGeneration", 0) ?: 0)
        env.put("command", parsed)
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun requestHandoffCandidate(call: PluginCall) {
        val sourceDeviceId = call.getString("sourceDeviceId") ?: return call.reject("missing sourceDeviceId")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "handoff_candidate_request")
        env.put("sourceDeviceId", sourceDeviceId)
        env.put("expectedGeneration", call.getInt("expectedGeneration", 0) ?: 0)
        env.put("expectedSnapshotRevision", call.getInt("expectedSnapshotRevision", 0) ?: 0)
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun sendTargetReady(call: PluginCall) {
        val transactionId = call.getString("transactionId") ?: return call.reject("missing transactionId")
        val sourceDeviceId = call.getString("sourceDeviceId") ?: return call.reject("missing sourceDeviceId")
        val sessionId = call.getString("sessionId") ?: return call.reject("missing sessionId")
        val env = buildTargetReadyEnvelope(
            protocolVersion,
            transactionId,
            call.getInt("generation", 0) ?: 0,
            call.getInt("snapshotRevision", 0) ?: 0,
            sourceDeviceId,
            sessionId,
        )
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun sendRelinquishAck(call: PluginCall) {
        val transactionId = call.getString("transactionId") ?: return call.reject("missing transactionId")
        val snapshotJson = call.getString("snapshotJson") ?: return call.reject("missing snapshotJson")
        val parsed = parseJsonObject(snapshotJson) ?: return call.reject("invalid snapshotJson")
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "relinquish_ack")
        env.put("transactionId", transactionId)
        env.put("snapshot", parsed)
        sendEnvelope(env)
        call.resolve()
    }

    @PluginMethod
    fun requestSnapshots(call: PluginCall) {
        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "request_snapshots")
        sendEnvelope(env)
        call.resolve()
    }

    private fun disconnectInternal() {
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
    fun attachToForegroundService(): Boolean {
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
    fun detachFromForegroundService() {
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

    private fun publishNativePlaybackSnapshot(onlyWhenPlaying: Boolean = false): Boolean {
        if (webSocket == null) return false
        val audioState = AudioPlugin.getFullStateFromActive() ?: return false
        if (onlyWhenPlaying && !audioState.optBoolean("isPlaying", false)) {
            return false
        }
        val snapshot = buildPlaybackSnapshot(
            sessionId = nativeSessionId,
            audioState = audioState,
            sampledAtSeconds = System.currentTimeMillis() / 1000.0,
        ) ?: return false

        nativeSnapshotRevision += 1
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
        expectedGeneration: Int,
        command: JSONObject
    ): Boolean {
        if (webSocket == null) return false

        val env = JSONObject()
        env.put("version", protocolVersion)
        env.put("messageId", java.util.UUID.randomUUID().toString())
        env.put("type", "command")
        env.put("targetDeviceId", targetDeviceId)
        env.put("expectedGeneration", expectedGeneration)
        env.put("command", command)
        sendEnvelope(env)
        return true
    }

    private fun dispatchEnvelope(json: String) {
        // Parse once to extract routing metadata, then forward the raw JSON
        // to the WebView so it can re-parse into the full Envelope type.
        val parsed = parseJsonObject(json)
        if (parsed != null) {
            // §9.2: track the incoming seq on every envelope.
            seqTracker.observe(extractSeq(parsed))
            // §9.1: dedup command/snapshot_projection envelopes by messageId.
            val type = extractType(parsed)
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
            // §9.1: emit `coordinationAck` when a command_ack arrives so the
            // WebView facade can resolve the pending sendCommand() promise.
            if (type == "command_ack") {
                val messageId = extractMessageId(parsed) ?: ""
                val result = parsed.opt("result")?.toString() ?: "{}"
                val ret = JSObject()
                ret.put("messageId", messageId)
                ret.put("resultJson", result)
                notifyListeners("coordinationAck", ret)
            }
            if (type == "command") {
                val command = parsed.optJSONObject("command")
                val messageId = extractMessageId(parsed)
                if (
                    command != null &&
                    AudioPlugin.executeRemoteControlCommandFromActive(command)
                ) {
                    if (messageId != null) {
                        sendEnvelope(buildCommandAckEnvelope(protocolVersion, messageId))
                    }
                    return
                }
            }
            if (type == "prepare_relinquish") {
                val transactionId = parsed.optString("transactionId", "")
                val audioState = AudioPlugin.pauseAndGetFullStateFromActive()
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
            }
            if (type == "handoff_candidate") {
                val snapshot = parsed.optJSONObject("snapshot")
                val transactionId = parsed.optString("transactionId", "")
                val sourceDeviceId = parsed.optString("sourceDeviceId", "")
                val sessionId = parsed.optString("sessionId", "")
                val accepted = snapshot != null &&
                    transactionId.isNotEmpty() &&
                    sourceDeviceId.isNotEmpty() &&
                    sessionId.isNotEmpty() &&
                    AudioPlugin.prepareHandoffPlaybackFromActive(
                        snapshot,
                        autoplay = false,
                    ) { prepared ->
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
                        }
                    }
                if (accepted) {
                    return
                }
            }
            if (type == "handoff_committed") {
                val snapshot = parsed.optJSONObject("snapshot")
                val accepted = snapshot != null &&
                    AudioPlugin.prepareHandoffPlaybackFromActive(
                        snapshot,
                        autoplay = true,
                    ) { }
                if (accepted) {
                    return
                }
            }
        }
        notifyListeners("coordinationEvent", JSObject().put("envelopeJson", json))
    }

    private fun scheduleReconnect() {
        // §13: exponential backoff with a cap. Tickets expire in 30s so the
        // native layer only emits the request; the WebView performs the
        // actual reconnect after refreshing the ticket.
        val attempt = (reconnectAttempts + 1).coerceAtMost(MAX_RECONNECT_ATTEMPTS)
        val delayMs = (BASE_RECONNECT_DELAY_MS * (1L shl (attempt - 1)))
            .coerceAtMost(MAX_RECONNECT_DELAY_MS)
        notifyState("reconnecting")
        mainHandler?.postDelayed(reconnectRunnable, delayMs)
    }

    private fun notifyReconnectNeeded(attempt: Int) {
        val ret = JSObject()
        ret.put("attempt", attempt)
        notifyListeners("coordinationReconnectNeeded", ret)
    }

    private fun notifyState(state: String) {
        val ret = JSObject()
        ret.put("state", state)
        ret.put("deviceId", deviceId ?: JSONObject.NULL)
        notifyListeners("coordinationStateChange", ret)
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
