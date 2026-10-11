package github.realtvop.aonsoku.plugins.coordination

import android.content.Context
import android.os.Build
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

/** Native account/session orchestration, independent of any UI or WebView. */
data class NativeDevice(val id: String, val name: String, val platform: String, val online: Boolean = false, val generation: Int = 0, val revision: Int = 0, val snapshot: JSONObject? = null, val confirmedAt: Long = 0)
class CoordinationApiException(val code: String, message: String) : Exception(message)

class CoordinationController private constructor(context: Context) {
    private val services = AppServices.getInstance(context)
    val transport = NativeCoordinationService.getInstance(context)
    val state = transport.state
    val devices = MutableStateFlow<List<NativeDevice>>(emptyList())
    val controlledDeviceId = MutableStateFlow<String?>(null)
    val notices = MutableSharedFlow<String>(extraBufferCapacity = 32)
    val enabled = MutableStateFlow(false)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val connectionMutex = Mutex()
    private val authMutex = Mutex()
    private val historyMutex = Mutex()
    private var reconnectJob: Job? = null
    private var periodicJob: Job? = null
    val deviceId: String? get() = transport.loadTokens()?.deviceId
    init {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            transport.events.collect { event ->
                when (event.name) {
                    "coordinationReconnectNeeded" -> connect()
                    "coordinationEvent" -> {
                        val env = runCatching { JSONObject(event.payload.optString("envelopeJson")) }.getOrNull() ?: return@collect
                        when (env.optString("type")) {
                            "welcome" -> { refreshDevices(); transport.requestPeerSnapshots(); synchronizeHistory() }
                            "devices_changed" -> updateDevices(env.optJSONArray("devices") ?: JSONArray())
                            "snapshot_projection" -> {
                                val id = env.optString("deviceId")
                                val snapshot = env.optJSONObject("snapshot")
                                devices.update { list ->
                                    val previous = list.find { it.id == id } ?: NativeDevice(id, id, "")
                                    list.filterNot { it.id == id } + previous.copy(online = env.optBoolean("isOnline", true), generation = env.optInt("generation"), revision = env.optInt("snapshotRevision"), snapshot = snapshot, confirmedAt = System.currentTimeMillis())
                                }
                            }
                            "handoff_committed" -> { controlledDeviceId.value = null; transport.endControl(); notices.emit("Playback transferred to this device") }
                            "handoff_failed", "error" -> notices.emit(env.optString("reason", env.optString("code", "Coordination failed")))
                            "history_changed" -> synchronizeHistory()
                            "session_superseded" -> notices.emit("Playback moved to another device")
                        }
                    }
                }
            }
        }
        scope.launch {
            val prefs = services.preferences.getAllPreferences()
            enabled.value = prefs["native.coordination.enabled"]?.toBooleanStrictOrNull() ?: (transport.loadConfig() != null && transport.loadTokens() != null)
            if (enabled.value && services.authentication.hasCredentials()) connect()
        }
    }
    fun configure(server: String, identity: String, deviceName: String) {
        require(java.net.URI(server).scheme in listOf("http", "https")) { "Invalid coordination server URL" }
        require(java.net.URI(identity).scheme in listOf("http", "https")) { "Invalid identity URL" }
        disconnect()
        val old = transport.loadConfig()
        if (old != (server.trimEnd('/') to identity.trimEnd('/'))) transport.clearTokens()
        transport.storeConfig(server.trimEnd('/'), identity.trimEnd('/'))
        enabled.value = true
        scope.launch { services.preferences.setPreference("native.coordination.deviceName", deviceName); services.preferences.setPreference("native.coordination.enabled", "true"); connect() }
    }
    fun connect() {
        if (!enabled.value || reconnectJob?.isActive == true) return
        reconnectJob = scope.launch {
            var attempt = 0
            while (enabled.value) {
                try {
                    connectionMutex.withLock {
                        if (transport.loadTokens() == null) register()
                        ensureToken()
                        val config = transport.loadConfig() ?: error("Configure cross-device playback first")
                        val tokens = transport.loadTokens() ?: error("Device registration failed")
                        val ticket = request("/v1/auth/ws-ticket", "POST", JSONObject()).getString("ticket")
                        transport.connect(config.first.replaceFirst("http", "ws") + "/v1/realtime", ticket, tokens.deviceId, 15, 1, transport.seqTracker.get())
                    }
                    if (periodicJob?.isActive != true) periodicJob = scope.launch { while (enabled.value) { delay(15000); synchronizeHistory() } }
                    break
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    if (e is CoordinationApiException && e.code == "device_revoked") { enabled.value = false; transport.clearTokens(); services.preferences.setPreference("native.coordination.enabled", "false"); notices.emit("This device was revoked. Register it again to reconnect."); break }
                    if (attempt == 0) notices.emit(e.message ?: "Unable to connect")
                    delay((1000L shl attempt.coerceAtMost(5)).coerceAtMost(30000)); attempt++
                }
            }
        }
    }
    fun disconnect() { enabled.value = false; reconnectJob?.cancel(); periodicJob?.cancel(); transport.endControl(); controlledDeviceId.value = null; transport.disconnect(); scope.launch { services.preferences.setPreference("native.coordination.enabled", "false") } }
    fun resume() { if (enabled.value && state.value != "connected") connect() else if (enabled.value) { transport.requestPeerSnapshots(); refreshDevices() } }
    private suspend fun proof(): JSONObject {
        val credentials = services.authentication.getCredentials() ?: error("Sign in first")
        val identity = transport.loadConfig()?.second ?: error("Configure identity URL")
        val challenge = request("/v1/auth/challenge", "POST", JSONObject().put("identityUrl", identity).put("username", credentials.username), false)
        return JSONObject().put("challengeId", challenge.getString("challengeId")).put("identityUrl", identity).put("username", credentials.username).put("authMode", credentials.authType).apply {
            if (credentials.authType == "token") { put("token", credentials.password); put("salt", SubsonicAuthBuilder.SALT) } else put("password", credentials.password)
        }
    }
    private suspend fun register() {
        val data = proof().put("deviceName", services.preferences.getAllPreferences()["native.coordination.deviceName"] ?: Build.MODEL).put("platform", "android").put("clientVersion", "0.30.0").put("capabilities", 15)
        val response = request("/v1/auth/register", "POST", data, false)
        transport.storeTokens(CoordinationTokenBundle(response.getString("accessToken"), response.getString("refreshToken"), System.currentTimeMillis() + response.getLong("expiresIn") * 1000, response.getString("deviceId"), response.getString("accountId"), response.optInt("historyLimit", 100)))
    }
    private suspend fun ensureToken(force: Boolean = false) = authMutex.withLock {
        val tokens = transport.loadTokens() ?: return@withLock
        if (!force && tokens.accessTokenExpiresAt > System.currentTimeMillis() + 30000) return@withLock
        val payload = JSONObject().put("deviceId", tokens.deviceId).put("refreshToken", tokens.refreshToken)
        val response = try { request("/v1/auth/token", "POST", payload, false) }
        catch (e: CoordinationApiException) {
            if (e.code != "authentication_failed") throw e
            val recovery = proof(); recovery.keys().forEach { key -> payload.put(key, recovery.get(key)) }
            request("/v1/auth/token", "POST", payload, false)
        }
        transport.storeTokens(tokens.copy(accessToken = response.getString("accessToken"), refreshToken = response.getString("refreshToken"), accessTokenExpiresAt = System.currentTimeMillis() + response.getLong("expiresIn") * 1000))
    }
    private suspend fun raw(path: String, method: String, body: JSONObject?, authorized: Boolean): CoordinationHttpResponse {
        val base = transport.loadConfig()?.first ?: error("Configure cross-device playback first")
        val headers = if (authorized) mapOf("Authorization" to "Bearer ${transport.loadTokens()?.accessToken ?: error("Register this device first")}") else emptyMap()
        return transport.request(base + path, method, body?.toString(), headers)
    }
    private suspend fun authorizedRaw(path: String, method: String = "GET", body: JSONObject? = null): CoordinationHttpResponse {
        ensureToken()
        var response = raw(path, method, body, true)
        if (response.status == 401) { ensureToken(true); response = raw(path, method, body, true) }
        return response
    }
    private suspend fun request(path: String, method: String = "GET", body: JSONObject? = null, authorized: Boolean = true): JSONObject {
        val response = if (authorized) authorizedRaw(path, method, body) else raw(path, method, body, false)
        val json = runCatching { JSONObject(response.body) }.getOrDefault(JSONObject())
        if (response.status !in 200..299) throw CoordinationApiException(json.optString("code", "http_${response.status}"), json.optString("reason", "Coordination HTTP ${response.status}"))
        return json
    }
    fun refreshDevices() = scope.launch {
        try {
            ensureToken()
            val response = authorizedRaw("/v1/devices")
            check(response.status in 200..299) { "Unable to list devices" }
            val rows = if (response.body.trimStart().startsWith("[")) JSONArray(response.body) else JSONObject(response.body).optJSONArray("devices") ?: JSONArray()
            updateDevices(rows)
        } catch (e: CancellationException) { throw e } catch (e: Exception) { notices.emit(e.message ?: "Unable to refresh devices") }
    }
    private fun updateDevices(rows: JSONArray) {
        devices.value = (0 until rows.length()).map { i -> val row = rows.getJSONObject(i); val previous = devices.value.find { it.id == row.optString("id") }; NativeDevice(row.getString("id"), row.optString("name"), row.optString("platform"), previous?.online ?: false, previous?.generation ?: 0, previous?.revision ?: 0, previous?.snapshot, previous?.confirmedAt ?: 0) }
    }
    suspend fun rename(id: String, name: String) { require(name.isNotBlank()); ensureToken(); request("/v1/devices/$id", "PATCH", JSONObject().put("name", name)); refreshDevices() }
    suspend fun revoke(id: String) { ensureToken(); request("/v1/devices/$id", "DELETE"); if (id == deviceId) { disconnect(); transport.clearTokens() }; refreshDevices() }
    suspend fun deleteAccount() { ensureToken(); request("/v1/account", "DELETE"); disconnect(); transport.clearTokens(); devices.value = emptyList() }
    fun control(id: String?) { controlledDeviceId.value = id; if (id == null) transport.endControl() else transport.beginControl(id) }
    fun send(command: JSONObject) {
        val id = controlledDeviceId.value ?: error("Choose a playback device")
        val target = devices.value.find { it.id == id } ?: error("Device is unavailable")
        check(target.online) { "Device is offline" }
        check(transport.sendCommand(id, target.generation, command)) { "Coordination is disconnected" }
    }
    fun handoff(id: String) { check(transport.handoffFromCache(id)) { "No fresh snapshot. Refresh devices and try again." } }
    fun recordHistory(song: SongEntity, eventId: String = UUID.randomUUID().toString()) { scope.launch { enqueueHistory(JSONObject().put("kind", "add").put("eventId", eventId).put("logicalPlaybackSessionId", UUID.randomUUID().toString()).put("songId", song.id).put("songTitle", song.title).put("songArtist", song.artist).put("songAlbum", song.album).put("songDuration", song.duration).put("clientEnteredAt", Instant.now().toString())) } }
    suspend fun enqueueHistory(operation: JSONObject) {
        if (!enabled.value) return
        historyMutex.withLock {
            val prefs = services.preferences.getAllPreferences()
            val outbox = JSONArray(prefs["native.coordination.outbox"] ?: "[]")
            outbox.put(operation.put("operationId", UUID.randomUUID().toString()))
            services.preferences.setPreference("native.coordination.outbox", outbox.toString())
        }
        synchronizeHistory()
    }
    private fun synchronizeHistory() = scope.launch {
        if (!enabled.value || state.value != "connected") return@launch
        historyMutex.withLock {
            try {
                ensureToken()
                val preferences = services.preferences
                val prefs = preferences.getAllPreferences()
                val importedKey = "native.coordination.imported.$deviceId"
                if (prefs[importedKey] != "true") {
                    val legacy = preferences.getPlayHistory(1000).mapNotNull { runCatching { JSONObject(it) }.getOrNull() }
                    try {
                        request("/v1/history/legacy-import", "POST", JSONObject().put("entries", JSONArray(legacy.map { JSONObject().put("songId", it.optString("id")).put("songTitle", it.optString("title")).put("songArtist", it.optString("artist")) })))
                    } catch (e: CoordinationApiException) { if (e.code != "bad_message") throw e }
                    preferences.setPreference(importedKey, "true")
                }
                val outbox = JSONArray(prefs["native.coordination.outbox"] ?: "[]")
                var pushed = 0
                while (pushed < outbox.length()) {
                    val batch = JSONArray((pushed until minOf(pushed + 1000, outbox.length())).map { outbox.getJSONObject(it) })
                    val result = request("/v1/history", "POST", JSONObject().put("operations", batch)).optJSONArray("results")
                    if (result != null && (0 until result.length()).any { !result.getJSONObject(it).optBoolean("accepted") }) error("History operation rejected")
                    pushed += batch.length()
                    preferences.setPreference("native.coordination.outbox", JSONArray((pushed until outbox.length()).map { outbox.getJSONObject(it) }).toString())
                }
                var revision = prefs["native.coordination.historyRevision"]?.toLongOrNull() ?: 0
                var generation = prefs["native.coordination.historyGeneration"]?.toIntOrNull() ?: 0
                val stored = JSONArray(prefs["native.coordination.historyEntries"] ?: "[]")
                val merged = (0 until stored.length()).map { stored.getJSONObject(it) }.associateBy { it.getString("eventId") }.toMutableMap()
                var limit = 100
                while (true) {
                    val response = request("/v1/history?after_revision=$revision&limit=1000")
                    val incomingGeneration = response.optInt("historyGeneration")
                    if (generation != incomingGeneration) { merged.clear(); generation = incomingGeneration; if (revision != 0L) { revision = 0; continue } }
                    val rows = response.optJSONArray("entries") ?: JSONArray()
                    val tombstones = response.optJSONArray("tombstones") ?: JSONArray()
                    val entryRows = (0 until rows.length()).map { rows.getJSONObject(it) }
                    val removedRows = (0 until tombstones.length()).map { tombstones.getJSONObject(it) }
                    val boundary = minOf(if (rows.length() == 1000) entryRows.last().optLong("revision") else Long.MAX_VALUE, if (tombstones.length() == 1000) removedRows.last().optLong("revision") else Long.MAX_VALUE)
                    val next = minOf(boundary, response.optLong("latestRevision"))
                    entryRows.filter { it.optLong("revision") <= next }.forEach { if (it.optBoolean("deleted")) merged.remove(it.getString("eventId")) else merged[it.getString("eventId")] = it }
                    removedRows.filter { it.optLong("revision") <= next }.forEach { merged.remove(it.getString("eventId")) }
                    limit = response.optInt("historyLimit", 100)
                    if (next <= revision) break
                    revision = next
                    if (revision >= response.optLong("latestRevision")) break
                }
                val entries = merged.values.sortedByDescending { it.optString("clientEnteredAt") }.take(limit)
                preferences.setPreferences(mapOf("native.coordination.historyEntries" to JSONArray(entries).toString(), "native.coordination.historyRevision" to revision.toString(), "native.coordination.historyGeneration" to generation.toString()))
                preferences.replacePlayHistory(entries.map { JSONObject().put("id", it.optString("songId")).put("title", it.optString("songTitle")).put("artist", it.optString("songArtist")).put("eventId", it.optString("eventId")).toString() })
            } catch (e: CancellationException) { throw e } catch (_: Exception) { /* Persistent outbox is retried next interval. */ }
        }
    }
    companion object {
        @Volatile private var instance: CoordinationController? = null
        fun getInstance(context: Context): CoordinationController = instance ?: synchronized(this) { instance ?: CoordinationController(context.applicationContext).also { instance = it } }
    }
}
