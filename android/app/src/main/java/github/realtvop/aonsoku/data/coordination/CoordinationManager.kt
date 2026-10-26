package github.realtvop.aonsoku.data.coordination

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import github.realtvop.aonsoku.BuildConfig
import github.realtvop.aonsoku.data.NetworkMonitor
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.Translations
import github.realtvop.aonsoku.player.PlayerController
import github.realtvop.aonsoku.player.RemotePlayback
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.coordination.CoordinationConnectOptions
import github.realtvop.aonsoku.plugins.coordination.CoordinationRuntime
import github.realtvop.aonsoku.plugins.coordination.CoordinationRuntimeEvent
import github.realtvop.aonsoku.plugins.coordination.CoordinationTokenBundle
import github.realtvop.aonsoku.ui.components.Toaster
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient

/** What the app knows about cross-device coordination. */
data class CoordinationState(
    val serverUrl: String = "",
    val identityUrl: String = "",
    /** Set once this device is registered on the coordination server. */
    val deviceId: String? = null,
    val connection: CoordinationConnection = CoordinationConnection.Disconnected,
    val devices: List<DeviceDto> = emptyList(),
    /** When the device list last arrived. */
    val lastSyncAt: Long? = null,
    val error: String? = null,
    /** The latest snapshot of each device that published one. */
    val snapshots: Map<String, DeviceSnapshot> = emptyMap(),
    val controlledDeviceId: String? = null,
) {
    val isRegistered: Boolean get() = deviceId != null

    val isConnected: Boolean get() = connection == CoordinationConnection.Connected
}

enum class HandoffPhase { Prepare, Committed }

/** The handoff this device asked for, and the one waiting for the user's consent. */
data class HandoffState(
    val phase: HandoffPhase? = null,
    val error: String? = null,
    /** A device whose playback is to continue here once the user agrees. */
    val pendingDeviceId: String? = null,
)

/**
 * The app side of cross-device coordination, what `CoordinationManager`, the
 * coordination store, and the remote-control hooks are on the web.
 *
 * [CoordinationRuntime] in `:core` owns the socket and everything playback
 * needs without the UI (publishing this device's playback, executing remote
 * commands, both sides of a handoff, and showing a controlled device in the
 * media notification). This class registers the device ([CoordinationApi]),
 * opens the socket with one-time tickets and opens it again after it drops,
 * keeps the device list and the devices' snapshots, and drives remote control
 * (through [PlayerController.showRemote]) and the handoffs the user starts.
 */
class CoordinationManager(
    private val context: Context,
    private val runtime: CoordinationRuntime,
    private val client: OkHttpClient,
    private val credentials: () -> ServerCredentials?,
    private val player: PlayerController,
    private val network: NetworkMonitor,
    private val toaster: Toaster,
    private val strings: () -> Translations,
    private val scope: CoroutineScope,
    private val accountKey: () -> String? = {
        credentials()?.let { "${it.serverUrl.trimEnd('/')}\u001f${it.username}" }
    },
) {
    private val _state = MutableStateFlow(CoordinationState())
    private val _handoff = MutableStateFlow(HandoffState())

    val state: StateFlow<CoordinationState> = _state.asStateFlow()
    val handoff: StateFlow<HandoffState> = _handoff.asStateFlow()

    private var api: CoordinationApi? = null
    private var started = false
    private var sessionGeneration = 0L
    private var observing = false
    private var connectJob: Job? = null
    private var retryJob: Job? = null
    private var retryAttempt = 0

    /** The device a handoff was requested from, until it ends. */
    private var handoffSource: String? = null
    private var handoffTimeout: Job? = null
    private var handoffClear: Job? = null

    // region Lifecycle

    /** Loads the registration and connects; called when a session starts. */
    fun start() {
        if (started) return
        started = true
        sessionGeneration++
        observe()
        val config = runtime.loadConfig()?.takeIf { it.first.isNotBlank() }
        val owner = context.getSharedPreferences("coordination_account_owner", 0)
        if (owner.getString("owner", null) != accountKey() || accountKey() == null) {
            runtime.clearTokens()
            owner.edit().clear().apply()
        }
        val tokens = runtime.loadTokens()
        _state.value = CoordinationState(
            serverUrl = config?.first.orEmpty(),
            identityUrl = config?.second.orEmpty(),
            deviceId = tokens?.deviceId?.takeIf { config != null },
        )
        api = if (config != null && tokens != null) newApi(config.first, tokens) else null
        reconnect()
    }

    /** Closes the socket at sign-out; the registration stays for the next session. */
    fun end() {
        if (!started) return
        started = false
        sessionGeneration++
        exitRemoteControl(notify = false)
        cancelHandoff()
        connectJob?.cancel()
        retryJob?.cancel()
        runtime.disconnect()
        api = null
        _state.value = CoordinationState()
    }

    fun onForeground() {
        if (!started) return
        retryAttempt = 0
        if (_state.value.isConnected) runtime.requestSnapshots() else reconnect()
    }

    private fun observe() {
        if (observing) return
        observing = true
        scope.launch { runtime.socketState.collect { refreshConnection() } }
        scope.launch { runtime.events.collect(::onRuntimeEvent) }
        scope.launch {
            network.isOnline.collect { online ->
                if (online && started) {
                    retryAttempt = 0
                    reconnect()
                }
            }
        }
    }

    // endregion

    // region Registration

    /**
     * Registers this device on the coordination server at [serverUrl] with the
     * signed-in music-server account, verified against [identityUrl], and
     * connects. Throws when that fails.
     */
    suspend fun connect(serverUrl: String, identityUrl: String, deviceName: String) {
        val generation = sessionGeneration
        val owner = accountKey()
        val server = serverUrl.trim().trimEnd('/')
        val identity = identityUrl.trim().trimEnd('/')
        runtime.storeConfig(server, identity)
        _state.update { it.copy(serverUrl = server, identityUrl = identity, error = null) }
        val signedIn = credentials() ?: throw IllegalStateException("Not signed in")
        val proof = SubsonicProof.from(signedIn, identity)
            ?: throw IllegalStateException("No valid authentication type")
        val api = newApi(server, tokens = null)
        val tokens = api.register(proof, deviceName.trim(), PLATFORM, BuildConfig.APP_VERSION)
        check(started && generation == sessionGeneration && owner == accountKey()) { "Music account changed" }
        context.getSharedPreferences("coordination_account_owner", 0).edit()
            .putString("owner", accountKey()).apply()
        this.api = api
        retryAttempt = 0
        _state.update { it.copy(deviceId = tokens.deviceId) }
        reconnect()
    }

    /** Revokes this device on the server, as far as it can be reached, and forgets it. */
    suspend fun disconnectThisDevice() {
        val api = api
        val deviceId = _state.value.deviceId
        if (api != null && deviceId != null) {
            runSuspendCatching { api.revokeDevice(deviceId) }
                .onFailure { Log.w(TAG, "Could not revoke this device", it) }
        }
        forget()
    }

    /** Deletes the coordination account with all its devices and history. */
    suspend fun deleteAccount() {
        val api = api ?: throw IllegalStateException("Not connected")
        api.deleteAccount()
        forget()
    }

    suspend fun renameDevice(id: String, name: String) {
        val api = api ?: throw IllegalStateException("Not connected")
        api.renameDevice(id, name.trim())
        refreshDevices()
    }

    suspend fun revokeDevice(id: String) {
        val api = api ?: throw IllegalStateException("Not connected")
        api.revokeDevice(id)
        refreshDevices()
    }

    /** The name this device suggests for itself: the one set in the system, or its model. */
    fun defaultDeviceName(): String {
        val name = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            runCatching {
                Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            }.getOrNull()
        } else {
            null
        }
        return name?.takeIf { it.isNotBlank() } ?: Build.MODEL?.takeIf { it.isNotBlank() } ?: PLATFORM
    }

    /** Drops the registration here; the server and its URL are remembered. */
    private fun forget() {
        context.getSharedPreferences("coordination_account_owner", 0).edit().clear().apply()
        exitRemoteControl(notify = false)
        cancelHandoff()
        connectJob?.cancel()
        retryJob?.cancel()
        runtime.clearTokens()
        runtime.disconnect()
        api = null
        _state.update { CoordinationState(serverUrl = it.serverUrl, identityUrl = it.identityUrl) }
    }

    private fun newApi(serverUrl: String, tokens: CoordinationTokenBundle?): CoordinationApi {
        val generation = sessionGeneration
        return CoordinationApi(
        serverUrl = serverUrl,
        client = client,
        tokens = tokens,
        onTokensChanged = { next ->
            if (started && generation == sessionGeneration) onTokensChanged(next)
        },
        recovery = { credentials()?.let { SubsonicProof.from(it, _state.value.identityUrl) } },
    )
    }

    private fun onTokensChanged(tokens: CoordinationTokenBundle?) {
        if (tokens != null) {
            runCatching { runtime.storeTokens(tokens) }
                .onFailure { Log.w(TAG, "Could not store the coordination tokens", it) }
            return
        }
        // Only a revoked device loses its tokens.
        scope.launch {
            if (api?.tokens != null || !_state.value.isRegistered) return@launch
            forget()
            _state.update {
                it.copy(error = DevicePlayback.handoffError(strings(), "device_revoked"))
            }
        }
    }

    // endregion

    // region Connection

    /** Opens the socket with a fresh ticket, unless it is open or opening. */
    fun reconnect() {
        val api = api ?: return
        if (!started || connectJob?.isActive == true) return
        val socket = CoordinationConnection.fromValue(runtime.socketState.value.state)
        if (socket == CoordinationConnection.Connected || socket == CoordinationConnection.Connecting) return
        retryJob?.cancel()
        retryJob = null
        val job = scope.launch {
            try {
                val ticket = api.wsTicket()
                val deviceId = api.tokens?.deviceId ?: return@launch
                if (this@CoordinationManager.api !== api || !started) return@launch
                runtime.connect(
                    CoordinationConnectOptions(
                        wsUrl = api.realtimeUrl,
                        ticket = ticket,
                        deviceId = deviceId,
                        capabilities = COORDINATION_CAPABILITIES,
                        protocolVersion = COORDINATION_PROTOCOL_VERSION,
                        lastSeq = runtime.lastSeq,
                    ),
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.w(TAG, "Could not open the coordination socket", error)
                // A revoked device is forgotten instead (onTokensChanged).
                if (api.tokens == null || this@CoordinationManager.api !== api) return@launch
                _state.update { it.copy(error = describe(error)) }
                connectJob = null
                scheduleRetry()
            }
        }
        connectJob = job
        job.invokeOnCompletion { refreshConnection() }
        refreshConnection()
    }

    /** Tries again later, waiting longer each time up to half a minute. */
    private fun scheduleRetry() {
        if (!started || api == null || retryJob?.isActive == true) return
        val delayMs = if (retryAttempt == 0) {
            0L
        } else {
            (BASE_RETRY_DELAY_MS shl (retryAttempt - 1).coerceAtMost(MAX_RETRY_SHIFT))
                .coerceAtMost(MAX_RETRY_DELAY_MS)
        }
        retryAttempt += 1
        retryJob = scope.launch {
            delay(delayMs)
            retryJob = null
            reconnect()
        }
        refreshConnection()
    }

    /** The socket's state, or that a ticket is on its way or a retry is due. */
    private fun refreshConnection() {
        val socket = CoordinationConnection.fromValue(runtime.socketState.value.state)
        val shown = when {
            socket == CoordinationConnection.Connected || socket == CoordinationConnection.Connecting -> socket
            !started || api == null -> socket
            connectJob?.isActive == true -> CoordinationConnection.Connecting
            retryJob?.isActive == true -> CoordinationConnection.Reconnecting
            else -> socket
        }
        if (_state.value.connection != shown) _state.update { it.copy(connection = shown) }
    }

    private fun onRuntimeEvent(event: CoordinationRuntimeEvent) {
        if (!started) return
        when (event) {
            is CoordinationRuntimeEvent.ReconnectNeeded -> scheduleRetry()
            is CoordinationRuntimeEvent.Envelope -> onEnvelope(event.json)
            // Commands are sent untracked; the runtime retries a stale generation itself.
            is CoordinationRuntimeEvent.CommandAck -> Unit
        }
    }

    // endregion

    // region Envelopes

    private fun onEnvelope(json: String) {
        val envelope = runCatching { CoordinationJson.parseToJsonElement(json).jsonObject }.getOrNull()
            ?: return
        when (envelope.text("type")) {
            "welcome" -> onWelcome()
            "devices_changed" -> envelope["devices"]?.let(::decodeDevices)?.let(::onDevices)
            "snapshot_projection" -> onProjection(envelope)
            "handoff_committed" -> onHandoffCommitted()
            "handoff_failed" -> onHandoffFailed(envelope.text("code") ?: "internal")
            "session_superseded" -> onSessionSuperseded(envelope.text("transferredToDevice"))
            "error" -> onServerError(envelope.text("code") ?: "internal", envelope.text("reason").orEmpty())
            "capability_disabled" -> onServerError(
                "protocol_incompatible",
                "feature disabled: ${envelope.text("feature").orEmpty()}",
            )
        }
    }

    private fun onWelcome() {
        retryAttempt = 0
        _state.update { it.copy(error = null) }
        scope.launch { refreshDevices() }
        // The devices that are playing right now, without waiting for their next publish.
        runtime.requestSnapshots()
        // A control session belongs to a connection: begin it again on the new one.
        _state.value.controlledDeviceId?.let(runtime::beginControlSession)
    }

    private suspend fun refreshDevices() {
        val api = api ?: return
        runSuspendCatching { api.devices() }
            .onSuccess(::onDevices)
            .onFailure { error ->
                Log.w(TAG, "Could not load the devices", error)
                _state.update { it.copy(error = "devices_refresh_failed: ${error.message}") }
            }
    }

    private fun onDevices(devices: List<DeviceDto>) {
        _state.update { it.copy(devices = devices, lastSyncAt = System.currentTimeMillis()) }
        val controlled = _state.value.controlledDeviceId ?: return
        val device = devices.firstOrNull { it.id == controlled }
        if (device == null) {
            exitRemoteControl()
            return
        }
        _state.value.snapshots[controlled]?.let { showRemote(device, it) }
    }

    private fun onProjection(envelope: JsonObject) {
        val deviceId = envelope.text("deviceId") ?: return
        val snapshot = (envelope["snapshot"] as? JsonObject)?.let {
            runCatching { CoordinationJson.decodeFromJsonElement(PlaybackSnapshot.serializer(), it) }
                .getOrNull()
        }
        val lastConfirmedAt = envelope.number("lastConfirmedAt") ?: 0.0
        val serverTime = envelope.number("serverTime") ?: lastConfirmedAt
        val entry = snapshot?.let {
            DeviceSnapshot(
                snapshot = it,
                isOnline = envelope.flag("isOnline") ?: true,
                generation = envelope.number("generation")?.toInt() ?: 0,
                snapshotRevision = envelope.number("snapshotRevision")?.toInt() ?: 0,
                receivedAt = System.currentTimeMillis(),
                ageSeconds = (serverTime - lastConfirmedAt).coerceAtLeast(0.0),
                receivedAtElapsed = SystemClock.elapsedRealtime(),
            )
        }
        _state.update { state ->
            state.copy(
                snapshots = if (entry == null) state.snapshots - deviceId else state.snapshots + (deviceId to entry),
            )
        }
        if (deviceId != _state.value.controlledDeviceId) return
        val device = _state.value.devices.firstOrNull { it.id == deviceId }
        if (entry == null || !entry.isOnline || !entry.snapshot.hasSong || device == null) {
            // Nothing left to control there.
            exitRemoteControl(message = DevicePlayback.handoffError(strings(), "target_offline"))
        } else {
            showRemote(device, entry)
        }
    }

    private fun onSessionSuperseded(transferredTo: String?) {
        val name = _state.value.devices.firstOrNull { it.id == transferredTo }?.name
            ?: strings().t("settings.crossDevice.playback.peerDevice")
        toaster.info(strings().t("settings.crossDevice.toast.sessionSuperseded", "deviceName" to name))
    }

    private fun onServerError(code: String, reason: String) {
        if (handoffSource != null) {
            val message = DevicePlayback.handoffError(strings(), code, reason)
            finishHandoff(phase = null, error = message)
            toaster.error(message)
            return
        }
        _state.update { it.copy(error = "$code: $reason") }
    }

    // endregion

    // region Remote control

    /** Controls [deviceId] from here: this device pauses and shows that one instead. */
    fun enterRemoteControl(deviceId: String) {
        val state = _state.value
        if (state.controlledDeviceId == deviceId || state.deviceId == deviceId) return
        val device = state.devices.firstOrNull { it.id == deviceId && !it.isControlling } ?: return
        val entry = state.snapshots[deviceId]?.takeIf { it.isOnline && it.snapshot.hasSong } ?: return
        if (state.controlledDeviceId != null) {
            runtime.endControlSession()
        } else {
            player.pauseLocal()
        }
        _state.update { it.copy(controlledDeviceId = deviceId) }
        runtime.beginControlSession(deviceId)
        showRemote(device, entry)
        // The notification shows the device once its next snapshot arrives.
        runtime.requestSnapshots()
        toaster.success(
            strings().t("settings.crossDevice.toast.remoteControlSuccess", "name" to device.name),
        )
    }

    /** Back to this device's own playback. */
    fun exitRemoteControl(notify: Boolean = true, message: String? = null) {
        if (_state.value.controlledDeviceId == null) return
        _state.update { it.copy(controlledDeviceId = null) }
        runtime.endControlSession()
        player.hideRemote()
        if (notify) {
            toaster.info(message ?: strings().t("settings.crossDevice.toast.exitRemoteControl"))
        }
    }

    private fun showRemote(device: DeviceDto, entry: DeviceSnapshot) {
        player.showRemote(RemotePlayback(device.id, device.name, entry), ::sendRemote)
    }

    private fun sendRemote(command: RemoteCommand) {
        if (!runtime.sendActiveControlCommand(command.toJson())) {
            Log.w(TAG, "Remote command not sent: ${command.type}")
        }
    }

    // endregion

    // region Handoff

    /**
     * Continues [deviceId]'s playback here. Asks first (through
     * [HandoffState.pendingDeviceId]) when this device is playing.
     */
    fun requestHandoff(deviceId: String) = requestHandoff(
        deviceId = deviceId,
        askFirst = player.local.value.isPlaying && _state.value.controlledDeviceId == null,
    )

    /** [askFirst]: something plays here that the handoff would replace. */
    internal fun requestHandoff(deviceId: String, askFirst: Boolean) {
        val entry = _state.value.snapshots[deviceId]
        if (entry != null && !entry.snapshot.hasSong) return
        if (askFirst) {
            _handoff.update { it.copy(pendingDeviceId = deviceId) }
            return
        }
        startHandoff(deviceId)
    }

    fun confirmHandoff() {
        val deviceId = _handoff.value.pendingDeviceId ?: return
        _handoff.update { it.copy(pendingDeviceId = null) }
        startHandoff(deviceId)
    }

    fun dismissHandoff() {
        _handoff.update { it.copy(pendingDeviceId = null) }
    }

    private fun startHandoff(deviceId: String) {
        val entry = _state.value.snapshots[deviceId]
        if (entry == null) {
            val message = DevicePlayback.handoffError(strings(), "snapshot_expired")
            _handoff.value = HandoffState(error = message)
            toaster.error(message)
            return
        }
        exitRemoteControl(notify = false)
        handoffTimeout?.cancel()
        handoffClear?.cancel()
        handoffSource = deviceId
        _handoff.value = HandoffState(phase = HandoffPhase.Prepare)
        if (!runtime.requestHandoffCandidateFromCache(deviceId)) {
            runtime.requestHandoffCandidate(deviceId, entry.generation, entry.snapshotRevision)
        }
        toaster.info(strings().t("settings.crossDevice.toast.preparingRelay"))
        handoffTimeout = scope.launch {
            delay(HANDOFF_TIMEOUT_MS)
            if (handoffSource == null) return@launch
            val message = DevicePlayback.handoffError(strings(), "source_pause_timeout")
            finishHandoff(phase = null, error = message)
            toaster.error(message)
        }
    }

    private fun onHandoffCommitted() {
        // The runtime has the queue playing here already.
        if (handoffSource == null) return
        finishHandoff(phase = HandoffPhase.Committed, error = null)
        toaster.success(strings().t("settings.crossDevice.toast.relaySuccess"))
    }

    private fun onHandoffFailed(code: String) {
        if (handoffSource != null) {
            val message = DevicePlayback.handoffError(strings(), code)
            finishHandoff(phase = null, error = message)
            toaster.error(message)
        } else {
            toaster.error(strings().t("settings.crossDevice.toast.relayFailed", "code" to code))
        }
    }

    private fun finishHandoff(phase: HandoffPhase?, error: String?) {
        handoffTimeout?.cancel()
        handoffClear?.cancel()
        handoffSource = null
        _handoff.value = HandoffState(phase = phase, error = error)
        if (phase == HandoffPhase.Committed) {
            handoffClear = scope.launch {
                delay(HANDOFF_CLEAR_DELAY_MS)
                _handoff.update { it.copy(phase = null) }
            }
        }
    }

    private fun cancelHandoff() {
        handoffTimeout?.cancel()
        handoffClear?.cancel()
        handoffSource = null
        _handoff.value = HandoffState()
    }

    // endregion

    private fun decodeDevices(element: JsonElement): List<DeviceDto>? = runCatching {
        CoordinationJson.decodeFromJsonElement(ListSerializer(DeviceDto.serializer()), element)
    }.getOrNull()

    private fun describe(error: Exception): String = when (error) {
        is CoordinationApiException -> "${error.code}: ${error.message}"
        else -> error.message ?: error.javaClass.simpleName
    }

    private fun JsonObject.text(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.number(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull

    private fun JsonObject.flag(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull

    companion object {
        private const val TAG = "Coordination"

        /** How this app names its platform to the server. */
        const val PLATFORM = "android"

        private const val BASE_RETRY_DELAY_MS = 1_000L
        private const val MAX_RETRY_DELAY_MS = 30_000L
        private const val MAX_RETRY_SHIFT = 5

        /** A handoff the source does not settle in this time has failed. */
        private const val HANDOFF_TIMEOUT_MS = 15_000L
        private const val HANDOFF_CLEAR_DELAY_MS = 1_000L
    }
}
