package github.realtvop.aonsoku.smoke

import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * An in-process coordination server: the `/v1` HTTP API and the realtime
 * socket of protocol version 1, enough for registering a device, keeping its
 * tokens fresh, and exchanging envelopes. Tests play the other devices by
 * sending envelopes ([send], [projection]) and read what the app sent
 * ([received]).
 */
class FakeCoordinationServer {
    private val server = MockWebServer()
    private val counter = AtomicInteger()

    /** "METHOD /path" of every HTTP request, in order. */
    val requests = CopyOnWriteArrayList<String>()

    /** Envelopes the app sent over the socket, in order. */
    val received = CopyOnWriteArrayList<JSONObject>()

    /** The devices of the account, as the API lists them. */
    val devices = CopyOnWriteArrayList<JSONObject>()

    /** The body of the last registration. */
    @Volatile
    var registration: JSONObject? = null

    @Volatile
    var accessToken = "access-0"
        private set

    @Volatile
    var refreshToken = "refresh-0"
        private set

    /** Lifetime of the access tokens handed out, in seconds. */
    @Volatile
    var expiresIn = 3_600L

    /**
     * While set, a refresh without a fresh proof of the account fails with
     * this code (`authentication_failed` or `device_revoked`).
     */
    @Volatile
    var refreshFailure: String? = null

    /** Tickets handed out, and the ones a socket was opened with. */
    val tickets = CopyOnWriteArrayList<String>()
    val socketsOpened = AtomicInteger()

    @Volatile
    private var socket: WebSocket? = null

    val url: String get() = server.url("/").toString().trimEnd('/')

    val isSocketOpen: Boolean get() = socket != null

    /** Id of the device the app registered. */
    val deviceId: String? get() = registration?.let { SELF_ID }

    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl?.encodedPath.orEmpty()
                requests += "${request.method} $path"
                return answer(request, path)
            }
        }
        server.start()
    }

    fun shutdown() {
        socket?.close(1000, "done")
        runCatching { server.shutdown() }
    }

    /** Adds another device to the account. */
    fun addDevice(id: String, name: String, platform: String = "web", controlling: Boolean = false) {
        devices += device(id, name, platform).put("isControlling", controlling)
    }

    /** Sends [payload] to the app, with the fields every envelope has. */
    fun send(type: String, payload: JSONObject = JSONObject()) {
        val envelope = JSONObject(payload.toString())
            .put("version", 1)
            .put("messageId", UUID.randomUUID().toString())
            .put("type", type)
            .put("serverTime", System.currentTimeMillis() / 1000)
        checkNotNull(socket) { "No socket is open" }.send(envelope.toString())
    }

    /** What [deviceId] plays, as the server relays it. */
    fun projection(
        deviceId: String,
        snapshot: JSONObject,
        isOnline: Boolean = true,
        generation: Int = 1,
        revision: Int = 1,
    ) = send(
        "snapshot_projection",
        JSONObject()
            .put("deviceId", deviceId)
            .put("sessionId", "session-$deviceId")
            .put("generation", generation)
            .put("snapshotRevision", revision)
            .put("snapshot", snapshot)
            .put("isOnline", isOnline)
            .put("lastConfirmedAt", System.currentTimeMillis() / 1000),
    )

    /** Tells the app that the device list changed. */
    fun devicesChanged() = send("devices_changed", JSONObject().put("devices", JSONArray(devices)))

    /** Closes the socket from this side, as a server going away does. */
    fun dropSocket() {
        checkNotNull(socket) { "No socket is open" }.close(1001, "going away")
        socket = null
    }

    /** Envelopes of [type] the app sent. */
    fun receivedOfType(type: String): List<JSONObject> = received.filter { it.optString("type") == type }

    private fun answer(request: RecordedRequest, path: String): MockResponse {
        val body = request.body.readUtf8().takeIf { it.isNotBlank() }?.let(::JSONObject)
        return when {
            request.method == "POST" && path == "/v1/auth/challenge" ->
                json(JSONObject().put("challengeId", "challenge-${counter.incrementAndGet()}"))
            request.method == "POST" && path == "/v1/auth/register" -> register(checkNotNull(body))
            request.method == "POST" && path == "/v1/auth/token" -> refresh(checkNotNull(body))
            // The socket proves itself with its ticket.
            request.method == "GET" && path == "/v1/realtime" -> upgrade(request)
            !authorized(request) -> error(401, "authentication_failed", "invalid access token")
            request.method == "POST" && path == "/v1/auth/ws-ticket" -> {
                val ticket = "ticket-${counter.incrementAndGet()}"
                tickets += ticket
                json(JSONObject().put("ticket", ticket).put("expiresIn", 30))
            }
            request.method == "GET" && path == "/v1/devices" -> MockResponse()
                .setHeader("Content-Type", "application/json")
                .setBody(JSONArray(devices).toString())
            request.method == "PATCH" && path.startsWith("/v1/devices/") -> {
                val id = path.removePrefix("/v1/devices/")
                val device = devices.firstOrNull { it.getString("id") == id }
                    ?: return error(404, "not_found", "no such device")
                device.put("name", checkNotNull(body).getString("name"))
                json(device)
            }
            request.method == "DELETE" && path.startsWith("/v1/devices/") -> {
                val id = path.removePrefix("/v1/devices/")
                devices.removeAll { it.getString("id") == id }
                MockResponse().setResponseCode(204)
            }
            request.method == "DELETE" && path == "/v1/account" -> {
                devices.clear()
                MockResponse().setResponseCode(204)
            }
            else -> error(404, "not_found", "no route")
        }
    }

    private fun register(body: JSONObject): MockResponse {
        registration = body
        devices.removeAll { it.getString("id") == SELF_ID }
        devices.add(
            0,
            device(SELF_ID, body.getString("deviceName"), body.getString("platform"))
                .put("clientVersion", body.optString("clientVersion")),
        )
        issueTokens()
        return json(
            JSONObject()
                .put("deviceId", SELF_ID)
                .put("accountId", ACCOUNT_ID)
                .put("accessToken", accessToken)
                .put("refreshToken", refreshToken)
                .put("expiresIn", expiresIn)
                .put("historyLimit", 500),
        )
    }

    private fun refresh(body: JSONObject): MockResponse {
        val failure = refreshFailure
        val proven = body.has("challengeId")
        if (failure == "device_revoked") return error(403, failure, "device revoked")
        if (failure != null && !proven) return error(401, failure, "invalid refresh token")
        if (body.optString("refreshToken") != refreshToken) {
            return error(401, "authentication_failed", "unknown refresh token")
        }
        issueTokens()
        return json(
            JSONObject()
                .put("accessToken", accessToken)
                .put("refreshToken", refreshToken)
                .put("expiresIn", expiresIn),
        )
    }

    private fun issueTokens() {
        val generation = counter.incrementAndGet()
        accessToken = "access-$generation"
        refreshToken = "refresh-$generation"
    }

    private fun authorized(request: RecordedRequest): Boolean =
        request.getHeader("Authorization") == "Bearer $accessToken"

    private fun upgrade(request: RecordedRequest): MockResponse {
        val ticket = request.requestUrl?.queryParameter("ticket")
        if (ticket == null || ticket !in tickets) return error(401, "ticket_expired", "unknown ticket")
        tickets.remove(ticket)
        return MockResponse().withWebSocketUpgrade(
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    socket = webSocket
                    socketsOpened.incrementAndGet()
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    val envelope = JSONObject(text)
                    received += envelope
                    if (envelope.optString("type") == "hello") {
                        send(
                            "welcome",
                            JSONObject()
                                .put("serverProtocolVersion", 1)
                                .put("negotiated", envelope.optInt("capabilities"))
                                .put("connectionId", "connection-${counter.incrementAndGet()}")
                                .put("deviceId", envelope.optString("deviceId")),
                        )
                    }
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    if (socket === webSocket) socket = null
                    webSocket.close(1000, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (socket === webSocket) socket = null
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (socket === webSocket) socket = null
                }
            },
        )
    }

    private fun device(id: String, name: String, platform: String) = JSONObject()
        .put("id", id)
        .put("name", name)
        .put("platform", platform)
        .put("capabilities", 15)
        .put("createdAt", "2026-01-01T00:00:00Z")
        .put("lastOnlineAt", "2026-10-01T00:00:00Z")
        .put("revokedAt", JSONObject.NULL)
        .put("historySyncCursor", 0)
        .put("legacyHistoryImported", false)

    private fun json(body: JSONObject) = MockResponse()
        .setHeader("Content-Type", "application/json")
        .setBody(body.toString())

    private fun error(status: Int, code: String, reason: String) = MockResponse()
        .setResponseCode(status)
        .setHeader("Content-Type", "application/json")
        .setBody(JSONObject().put("code", code).put("reason", reason).toString())

    companion object {
        const val SELF_ID = "device-self"
        const val ACCOUNT_ID = "account-1"

        /** What a device playing [songId] of album al-1 publishes. */
        fun snapshot(
            songId: String,
            context: List<String>,
            index: Int = context.indexOf(songId).coerceAtLeast(0),
            progress: Double = 12.0,
            playing: Boolean = true,
            userQueue: List<String> = emptyList(),
            shuffle: Boolean = false,
            repeat: String = "off",
            source: String? = "album:al-1",
        ): JSONObject = JSONObject()
            .put("sessionId", "session-$songId")
            .put("logicalPlaybackSessionId", "session-$songId")
            .put("mediaKind", "song")
            .put("songId", songId)
            .put("progressSeconds", progress)
            .put("durationSeconds", 200.0)
            .put("isPlaying", playing)
            .put("sampledAt", System.currentTimeMillis() / 1000.0)
            .put("contextQueue", JSONArray(context))
            .put("contextIndex", index)
            .put("sourceId", source ?: JSONObject.NULL)
            .put("sourceName", "Northern Lights")
            .put("userQueue", JSONArray(userQueue))
            .put("inUserQueue", false)
            .put("restorePrevious", JSONArray())
            .put("shuffle", shuffle)
            .put("repeat", repeat)
            .put("volume", 0.5)
            .put("accumulatedPlaySeconds", 0)
            .put("historyWritten", false)
            .put("nowPlayingSent", false)
            .put("scrobbleSent", false)
    }
}
