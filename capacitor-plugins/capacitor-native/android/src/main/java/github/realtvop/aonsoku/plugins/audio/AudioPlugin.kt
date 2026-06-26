package github.realtvop.aonsoku.plugins.audio

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import github.realtvop.aonsoku.plugins.bridge.AndroidCredentialStore
import github.realtvop.aonsoku.plugins.bridge.SubsonicHttpClient
import github.realtvop.aonsoku.plugins.data.db.AonsokuDatabase
import github.realtvop.aonsoku.plugins.data.db.toJSObject
import github.realtvop.aonsoku.plugins.debug.NativeLogger
import github.realtvop.aonsoku.plugins.error.AonsokuNativeError
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.CompletableDeferred
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

@CapacitorPlugin(
    name = "AonsokuNativeAudio",
    permissions = [
        Permission(
            alias = "post_notifications",
            strings = ["android.permission.POST_NOTIFICATIONS"]
        )
    ]
)
class AudioPlugin : Plugin() {
    private val pluginName = "AudioPlugin"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var playbackService: PlaybackService? = null
    private var isBound = false
    private var isWebViewActive = true
    private var currentRequestId: String? = null
    private var playerListener: Player.Listener? = null

    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val serviceReady = CompletableDeferred<PlaybackService>()

    private suspend fun awaitService(timeoutMs: Long = 5000): PlaybackService {
        return withTimeout(timeoutMs) { serviceReady.await() }
    }

    private val httpClient = SubsonicHttpClient()
    private val credentialStore: AndroidCredentialStore by lazy {
        AndroidCredentialStore(context)
    }

    private var sleepTimerHandler: Handler? = null
    private var sleepTimerEndTime: Long = 0
    private var sleepTimerMode: String = "duration"

    private val db by lazy { AonsokuDatabase.getInstance(context) }

    private var headphoneReceiver: HeadphoneUnplugReceiver? = null
    private var volumeReceiver: VolumeChangeReceiver? = null
    private var audioDeviceCallback: android.media.AudioDeviceCallback? = null

    private inner class VolumeChangeReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == "android.media.VOLUME_CHANGED_ACTION") {
                val streamType = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
                if (streamType == AudioManager.STREAM_MUSIC) {
                    val volume = getSystemVolumePercentage()
                    notifyListeners("systemVolumeChanged", JSObject().apply {
                        put("volume", volume)
                    })
                }
            }
        }
    }

    private inner class HeadphoneUnplugReceiver : android.content.BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                notifyListeners("routeChanged", JSObject().apply {
                    put("requestId", currentRequestId ?: JSONObject.NULL)
                    put("reason", "headphone_unplugged")
                })
            }
        }
    }

    private val downloadListener = object : PlaybackService.DownloadListener {
        override fun onDownloadProgress(songId: String, loaded: Long, total: Long) {
            if (playbackService?.isBackgroundCache(songId) == true) return
            notifyListeners("downloadProgress", JSObject().apply {
                put("songId", songId)
                put("loaded", loaded)
                put("total", total)
            })
        }

        override fun onDownloadCompleted(songId: String, fileUri: String, contentType: String, sizeBytes: Long) {
            if (playbackService?.isBackgroundCache(songId) == true) {
                playbackService?.removeBackgroundCache(songId)
                notifyListeners("streamCacheCompleted", JSObject().apply {
                    put("songId", songId)
                    put("uri", fileUri)
                    put("contentType", contentType)
                    put("sizeBytes", sizeBytes)
                })
                return
            }
            notifyListeners("downloadCompleted", JSObject().apply {
                put("songId", songId)
                put("uri", fileUri)
                put("contentType", contentType)
                put("sizeBytes", sizeBytes)
            })
        }

        override fun onDownloadFailed(songId: String, errorMessage: String) {
            if (playbackService?.isBackgroundCache(songId) == true) {
                playbackService?.removeBackgroundCache(songId)
                return
            }
            notifyListeners("downloadFailed", JSObject().apply {
                put("songId", songId)
                put("error", errorMessage)
            })
        }
    }

    private val serviceListener = object : PlaybackService.Listener {
        override fun onRemoteCommand(command: String, position: Double?) {
            emitRemoteCommand(command, position)
        }

        override fun onRemoteControlCommand(
            command: JSONObject,
            targetDeviceId: String?,
            expectedGeneration: Int?
        ) {
            emitRemoteControlCommand(command, targetDeviceId, expectedGeneration)
        }

        override fun onQueueStateChanged(currentIndex: Int, songId: String, reason: String, isInUserQueue: Boolean) {
            val data = JSObject().apply {
                put("currentIndex", currentIndex)
                put("songId", songId)
                put("reason", reason)
                put("isInUserQueue", isInUserQueue)
            }
            notifyListeners("queueStateChanged", data)
        }

        override fun onQueueContentsChanged(reason: String) {
            val data = JSObject().apply {
                put("reason", reason)
            }
            notifyListeners("queueContentsChanged", data)
        }

        override fun onPlaybackStateChanged(state: String) {
            emitPlaybackState(state, currentRequestId)
        }

        override fun onEnded(reason: String) {
            notifyListeners("ended", JSObject().apply {
                put("requestId", currentRequestId ?: JSONObject.NULL)
                put("reason", reason)
            })
            emitPlaybackState("ended", currentRequestId)
        }

        override fun onSleepTimerEndOfTrack() {
            fireSleepTimerEvent("endOfTrack")
        }

        override fun onError(code: String, message: String) {
            notifyListeners("error", JSObject().apply {
                put("code", code)
                put("message", message)
                put("requestId", currentRequestId ?: JSONObject.NULL)
            })
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? PlaybackService.LocalBinder
            val currentService = binder?.getService()
            playbackService = currentService
            isBound = true
            NativeLogger.info("PlaybackService connected", "audio-plugin")

            currentService?.addListener(serviceListener)
            currentService?.addDownloadListener(downloadListener)
            setupPlayerListener()
            if (!serviceReady.isCompleted) {
                serviceReady.complete(currentService ?: return)
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            NativeLogger.warn("PlaybackService disconnected", "audio-plugin")
            playbackService?.removeListener(serviceListener)
            playbackService?.removeDownloadListener(downloadListener)
            playbackService = null
            isBound = false
            serviceReady.completeExceptionally(IllegalStateException("PlaybackService disconnected"))
        }
    }

    override fun load() {
        super.load()
        NativeLogger.info("AudioPlugin loaded, binding PlaybackService", "audio-plugin")
        bindPlaybackService()
        registerAudioFocusListener()
        registerHeadphoneReceiver()
        registerVolumeReceiver()
        registerAudioDeviceCallback()
    }

    override fun handleOnPause() {
        isWebViewActive = false
        stopProgressUpdates()
        super.handleOnPause()
    }

    override fun handleOnResume() {
        super.handleOnResume()
        isWebViewActive = true
        val player = playbackService?.getPlayer()
        if (player != null && player.isPlaying) {
            emitProgress()
            startProgressUpdates()
        }
        // Emit volume on resume to ensure UI is in sync
        val volume = getSystemVolumePercentage()
        notifyListeners("systemVolumeChanged", JSObject().apply {
            put("volume", volume)
        })
    }

    override fun handleOnStop() {
        super.handleOnStop()
        pluginScope.launch {
            playbackService?.submitPendingScrobbles()
            playbackService?.persistence?.flushNow()
        }
    }

    override fun handleOnDestroy() {
        playbackService?.removeListener(serviceListener)
        playbackService?.removeDownloadListener(downloadListener)
        if (isBound) {
            context.unbindService(connection)
            isBound = false
        }
        mainHandler.removeCallbacks(progressRunnable)
        cancelSleepTimerInternal()
        unregisterAudioFocusListener()
        unregisterHeadphoneReceiver()
        unregisterVolumeReceiver()
        unregisterAudioDeviceCallback()
        pluginScope.cancel()
        super.handleOnDestroy()
    }

    private fun bindPlaybackService() {
        val intent = Intent(context, PlaybackService::class.java)
        try {
            context.startService(intent)
        } catch (_: Exception) {
        }
        context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
    }

    // MARK: - Audio Focus

    private fun registerAudioFocusListener() {
        // No-op: ExoPlayer manages audio focus automatically via setAudioAttributes(..., true)
    }

    private fun unregisterAudioFocusListener() {
        // No-op
    }

    private fun requestAudioFocus(): Int {
        // No-op: ExoPlayer requests audio focus automatically on play()
        return AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        // No-op
    }

    // MARK: - Headphone Route Receiver

    private fun registerHeadphoneReceiver() {
        val receiver = HeadphoneUnplugReceiver()
        headphoneReceiver = receiver
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(receiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        }
    }

    private fun unregisterHeadphoneReceiver() {
        headphoneReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
        }
        headphoneReceiver = null
    }

    private fun registerVolumeReceiver() {
        val receiver = VolumeChangeReceiver()
        volumeReceiver = receiver
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, IntentFilter("android.media.VOLUME_CHANGED_ACTION"), Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(receiver, IntentFilter("android.media.VOLUME_CHANGED_ACTION"))
        }
    }

    private fun unregisterVolumeReceiver() {
        volumeReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
        }
        volumeReceiver = null
    }

    private fun getSystemVolumePercentage(): Double {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return if (max > 0) current.toDouble() / max.toDouble() else 0.0
    }

    private fun registerAudioDeviceCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val callback = object : android.media.AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out android.media.AudioDeviceInfo>?) {
                    triggerVolumeUpdate()
                }

                override fun onAudioDevicesRemoved(removedDevices: Array<out android.media.AudioDeviceInfo>?) {
                    triggerVolumeUpdate()
                }
            }
            audioManager.registerAudioDeviceCallback(callback, mainHandler)
            audioDeviceCallback = callback
        }
    }

    private fun unregisterAudioDeviceCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioDeviceCallback?.let { callback ->
                val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.unregisterAudioDeviceCallback(callback)
            }
            audioDeviceCallback = null
        }
    }

    private fun triggerVolumeUpdate() {
        notifyVolumeChanged()
        mainHandler.postDelayed({
            notifyVolumeChanged()
        }, 300)
        mainHandler.postDelayed({
            notifyVolumeChanged()
        }, 800)
    }

    private fun notifyVolumeChanged() {
        val volume = getSystemVolumePercentage()
        notifyListeners("systemVolumeChanged", JSObject().apply {
            put("volume", volume)
        })
    }



    // MARK: - Sleep Timer

    @PluginMethod
    fun setSleepTimer(call: PluginCall) {
        val seconds = call.getDouble("seconds") ?: 0.0
        val mode = call.getString("mode") ?: "duration"

        cancelSleepTimerInternal()

        pluginScope.launch {
            try {
                val service = awaitService()
                service.sleepTimerMode = mode
            } catch (_: TimeoutCancellationException) {}
        }

        if (mode == "endOfTrack") {
            sleepTimerMode = "endOfTrack"
            sleepTimerEndTime = 0
        } else if (seconds > 0) {
            sleepTimerEndTime = System.currentTimeMillis() + (seconds * 1000).toLong()
            sleepTimerMode = "duration"
            val handler = Handler(Looper.getMainLooper())
            sleepTimerHandler = handler
            handler.postDelayed({
                fireSleepTimer()
            }, (seconds * 1000).toLong())
        }
        call.resolve()
    }

    @PluginMethod
    fun cancelSleepTimer(call: PluginCall) {
        cancelSleepTimerInternal()
        pluginScope.launch {
            try {
                val service = awaitService()
                service.sleepTimerMode = "duration"
            } catch (_: TimeoutCancellationException) {}
        }
        call.resolve()
    }

    @PluginMethod
    fun getSleepTimerRemaining(call: PluginCall) {
        val remaining = if (sleepTimerEndTime > 0) {
            maxOf(0, sleepTimerEndTime - System.currentTimeMillis()) / 1000
        } else 0
        call.resolve(JSObject().apply {
            put("remainingSeconds", remaining.toDouble())
        })
    }

    private fun cancelSleepTimerInternal() {
        sleepTimerHandler?.removeCallbacksAndMessages(null)
        sleepTimerHandler = null
        sleepTimerEndTime = 0
        sleepTimerMode = "duration"
    }

    private fun fireSleepTimer() {
        playbackService?.getPlayer()?.let { player ->
            player.pause()
        }
        playbackService?.persistence?.flushNow()
        cancelSleepTimerInternal()
        playbackService?.sleepTimerMode = "duration"
        fireSleepTimerEvent("duration")
    }

    private fun fireSleepTimerEvent(reason: String) {
        emitPlaybackState("paused", currentRequestId)
        notifyListeners("sleepTimerFired", JSObject().apply {
            put("reason", reason)
        })
    }

    // MARK: - Player Listener

    private fun setupPlayerListener() {
        val player = playbackService?.getPlayer() ?: return
        if (playerListener != null) {
            player.removeListener(playerListener!!)
        }

        playerListener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                handlePlaybackStateChanged(playbackState)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                handleIsPlayingChanged(isPlaying)
            }

            override fun onPlayerError(error: PlaybackException) {
                handlePlayerError(error)
            }
        }
        player.addListener(playerListener!!)
    }

    private fun handlePlaybackStateChanged(playbackState: Int) {
        val player = playbackService?.getPlayer() ?: return
        val requestId = currentRequestId
        when (playbackState) {
            Player.STATE_BUFFERING -> {
                notifyListeners("bufferingChanged", JSObject().apply {
                    put("isBuffering", true)
                    put("requestId", requestId ?: JSONObject.NULL)
                })
                emitPlaybackState("loading", requestId)
            }
            Player.STATE_READY -> {
                notifyListeners("bufferingChanged", JSObject().apply {
                    put("isBuffering", false)
                    put("requestId", requestId ?: JSONObject.NULL)
                })

                val rawDuration = player.duration
                if (rawDuration != C.TIME_UNSET) {
                    notifyListeners("durationChanged", JSObject().apply {
                        put("duration", rawDuration / 1000.0)
                        put("requestId", requestId ?: JSONObject.NULL)
                    })
                }

                if (!player.playWhenReady && !player.isPlaying) {
                    emitPlaybackState("paused", requestId)
                } else if (player.isPlaying) {
                    emitPlaybackState("playing", requestId)
                }
            }
            Player.STATE_ENDED -> {
                val service = playbackService
                if (service != null && service.isQueueEngineActive) {
                } else {
                    notifyListeners("bufferingChanged", JSObject().apply {
                        put("isBuffering", false)
                        put("requestId", requestId ?: JSONObject.NULL)
                    })

                    notifyListeners("ended", JSObject().apply {
                        put("requestId", requestId ?: JSONObject.NULL)
                        put("reason", "finished")
                    })
                    emitPlaybackState("ended", requestId)
                }
            }
            Player.STATE_IDLE -> {
                if (player.playbackState == Player.STATE_IDLE) {
                    notifyListeners("bufferingChanged", JSObject().apply {
                        put("isBuffering", false)
                        put("requestId", requestId ?: JSONObject.NULL)
                    })
                    emitPlaybackState("idle", requestId)
                }
            }
        }
    }

    private fun handleIsPlayingChanged(isPlaying: Boolean) {
        val requestId = currentRequestId
        if (isPlaying) {
            startProgressUpdates()
            emitPlaybackState("playing", requestId)
        } else {
            stopProgressUpdates()
            val player = playbackService?.getPlayer()
            if (player != null) {
                if (player.playbackState != Player.STATE_ENDED && player.playbackState != Player.STATE_IDLE) {
                    if (!player.playWhenReady) {
                        emitPlaybackState("paused", requestId)
                    }
                }
            }
        }
    }

    private fun handlePlayerError(error: PlaybackException) {
        val requestId = currentRequestId
        notifyListeners("bufferingChanged", JSObject().apply {
            put("isBuffering", false)
            put("requestId", requestId ?: JSONObject.NULL)
        })

            val mappedCode = mapPlayerErrorCode(error)
        NativeLogger.error("Player error: ${mappedCode} - ${error.localizedMessage}", "audio-plugin")
        notifyListeners("error", JSObject().apply {
            put("code", mappedCode)
            put("message", error.localizedMessage ?: "Unknown ExoPlayer error")
            put("requestId", requestId ?: JSONObject.NULL)
        })
        emitPlaybackState("failed", requestId)
    }

    private fun mapPlayerErrorCode(error: PlaybackException): String {
        return when (error.errorCode) {
            PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW,
            PlaybackException.ERROR_CODE_TIMEOUT,
            PlaybackException.ERROR_CODE_IO_UNSPECIFIED -> "network_error"
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
            PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FAILED,
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED -> "invalid_media"
            PlaybackException.ERROR_CODE_DRM_UNSPECIFIED,
            PlaybackException.ERROR_CODE_DRM_SCHEME_UNSUPPORTED,
            PlaybackException.ERROR_CODE_DRM_PROVISIONING_FAILED,
            PlaybackException.ERROR_CODE_DRM_CONTENT_ERROR,
            PlaybackException.ERROR_CODE_DRM_LICENSE_ACQUISITION_FAILED,
            PlaybackException.ERROR_CODE_DRM_DISALLOWED_OPERATION -> "drm_error"
            PlaybackException.ERROR_CODE_REMOTE_ERROR -> "remote_error"
            else -> "playback_failed"
        }
    }

    // MARK: - Progress

    private val progressRunnable = object : Runnable {
        override fun run() {
            emitProgress()
            mainHandler.postDelayed(this, 250)
        }
    }

    private fun startProgressUpdates() {
        mainHandler.removeCallbacks(progressRunnable)
        mainHandler.post(progressRunnable)
    }

    private fun stopProgressUpdates() {
        mainHandler.removeCallbacks(progressRunnable)
    }

    private fun isWebViewVisible(): Boolean {
        val webView = bridge?.webView ?: return false
        return isWebViewActive && webView.isShown && webView.windowVisibility == android.view.View.VISIBLE
    }

    private fun emitProgress() {
        val player = playbackService?.getPlayer() ?: return
        val duration = player.duration
        val currentPosition = player.currentPosition
        val bufferedPosition = player.bufferedPosition

        if (isWebViewVisible()) {
            val data = JSObject().apply {
                put("currentTime", currentPosition / 1000.0)
                put("duration", if (duration == C.TIME_UNSET) 0.0 else duration / 1000.0)
                put("bufferedTime", bufferedPosition / 1000.0)
                put("requestId", currentRequestId ?: JSONObject.NULL)
            }
            notifyListeners("progress", data)
        }

        playbackService?.persistence?.updateProgress(currentPosition / 1000.0)
    }

    private fun emitPlaybackState(state: String, requestId: String?) {
        val data = JSObject().apply {
            put("state", state)
            put("requestId", requestId ?: JSONObject.NULL)
        }
        notifyListeners("playbackStateChanged", data)
    }

    private fun emitRemoteCommand(command: String, position: Double? = null) {
        val data = JSObject().apply {
            put("command", command)
            if (position != null) {
                put("position", position)
            }
            put("requestId", currentRequestId ?: JSONObject.NULL)
        }
        notifyListeners("remoteCommand", data)
    }

    private fun emitRemoteControlCommand(
        command: JSONObject,
        targetDeviceId: String?,
        expectedGeneration: Int?
    ) {
        val data = JSObject().apply {
            put("command", command)
            if (targetDeviceId != null) {
                put("targetDeviceId", targetDeviceId)
            }
            if (expectedGeneration != null) {
                put("expectedGeneration", expectedGeneration)
            }
            put("requestId", currentRequestId ?: JSONObject.NULL)
        }
        notifyListeners("remoteControlCommand", data)
    }

    private fun checkAndRequestNotificationPermission(call: PluginCall, onDone: () -> Unit) {
        if (Build.VERSION.SDK_INT >= 33) {
            if (getPermissionState("post_notifications") != PermissionState.GRANTED) {
                requestPermissionForAlias("post_notifications", call, "notificationPermissionCallback")
                return
            }
        }
        onDone()
    }

    @PermissionCallback
    fun notificationPermissionCallback(call: PluginCall) {
        when (call.methodName) {
            "play" -> executePlay(call)
            "load" -> executeLoad(call)
        }
    }

    // MARK: - Plugin Methods

    @PluginMethod
    fun load(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                if (service.isQueueEngineActive) {
                    call.resolve()
                    return@launch
                }
                checkAndRequestNotificationPermission(call) {
                    executeLoad(call)
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    private fun executeLoad(call: PluginCall) {
        NativeLogger.debug("Loading audio source", "audio-plugin")
        val sourceObj = call.getObject("source") ?: run {
            call.reject("Missing audio source.")
            return
        }

        val parsedSource = NativeAudioSourceParser.parseSource(sourceObj) ?: run {
            call.reject("Failed to parse audio source.")
            return
        }

        val parsedMetadata = NativeAudioSourceParser.parseMetadata(call.getObject("metadata"))
        val autoplay = call.getBoolean("autoplay", false) ?: false
        val startTime = call.getDouble("startTime", 0.0) ?: 0.0
        val requestId = call.getString("requestId")

        currentRequestId = requestId

        val songId = parsedSource.songId
        val songDuration = parsedMetadata?.duration ?: 0.0

        when (parsedSource.kind) {
            "stream" -> {
                val url = parsedSource.url
                if (url.isNullOrEmpty()) {
                    call.reject("Missing URL for stream source")
                    return
                }
                val resolvedUrl = if (url.startsWith("aonsoku-media://")) {
                    val song = QueueSong(
                        id = songId ?: "",
                        title = parsedMetadata?.title ?: "",
                        artist = parsedMetadata?.artist ?: "",
                        artistId = null,
                        album = parsedMetadata?.album ?: "",
                        albumId = null,
                        duration = songDuration,
                        coverArtId = null,
                        streamUrl = url,
                        cachedFileUri = null
                    )
                    val resolver = NativeSourceResolver(context, credentialStore)
                    val resolved = resolver.resolveSource(song)
                    if (resolved == null) {
                        call.reject("Failed to resolve stream source: missing or invalid credentials for aonsoku-media URL")
                        return
                    }
                    resolved.first
                } else {
                    url
                }
                playbackService?.handleScrobbleSongEnded()
                if (songId != null) {
                    playbackService?.handleScrobbleSongStarted(songId, songDuration)
                }
                loadMediaAndPlay(resolvedUrl, parsedMetadata, startTime, autoplay, requestId, onResolved = { call.resolve() }, onRejected = { msg -> call.reject(msg) })
            }
            "radio" -> {
                val url = parsedSource.url
                if (url.isNullOrEmpty()) {
                    call.reject("Missing URL for radio source")
                    return
                }
                playbackService?.handleScrobbleSongEnded()
                loadMediaAndPlay(url, parsedMetadata, startTime, autoplay, requestId, onResolved = { call.resolve() }, onRejected = { msg -> call.reject(msg) })
            }
            "native-file" -> {
                val uri = parsedSource.uri
                if (uri.isNullOrEmpty()) {
                    call.reject("Missing URI for native-file source")
                    return
                }
                if (uri.startsWith("content://")) {
                    playbackService?.handleScrobbleSongEnded()
                    if (songId != null) {
                        playbackService?.handleScrobbleSongStarted(songId, songDuration)
                    }
                    loadMediaAndPlay(uri, parsedMetadata, startTime, autoplay, requestId, onResolved = { call.resolve() }, onRejected = { msg -> call.reject(msg) })
                } else {
                    val path = if (uri.startsWith("file://")) uri.substring(7) else uri
                    val file = File(path)
                    if (!file.exists()) {
                        call.reject("Native file does not exist: $path")
                        return
                    }
                    playbackService?.handleScrobbleSongEnded()
                    if (songId != null) {
                        playbackService?.handleScrobbleSongStarted(songId, songDuration)
                    }
                    loadMediaAndPlay(uri, parsedMetadata, startTime, autoplay, requestId, onResolved = { call.resolve() }, onRejected = { msg -> call.reject(msg) })
                }
            }
            "blob" -> {
                NativeLogger.error("Blob source not supported on Android native", "audio-plugin")
                call.reject("Blob source is not supported on Android native playback. Use stream or native-file instead.")
            }
            else -> {
                NativeLogger.error("Unknown source kind: ${parsedSource.kind}", "audio-plugin")
                call.reject("Unsupported audio source kind: ${parsedSource.kind}")
            }
        }
    }

    private fun loadMediaAndPlay(
        url: String,
        parsedMetadata: ParsedMetadata?,
        startTime: Double,
        autoplay: Boolean,
        requestId: String?,
        onResolved: () -> Unit,
        onRejected: ((String) -> Unit)? = null
    ) {
        val mediaMetadataBuilder = MediaMetadata.Builder()
        val meta = parsedMetadata
        if (meta != null) {
            mediaMetadataBuilder.setTitle(meta.title)
            mediaMetadataBuilder.setArtist(meta.artist)
            mediaMetadataBuilder.setAlbumTitle(meta.album)
            if (meta.duration != null) {
                mediaMetadataBuilder.setDurationMs((meta.duration!!.toLong() * 1000L))
            }
            if (meta.artworkUrl != null) {
                mediaMetadataBuilder.setArtworkUri(Uri.parse(meta.artworkUrl))
            }
        }

        val customMeta = mediaMetadataBuilder.build()
        playbackService?.currentSongMetadata = customMeta

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(url))
            .setMediaMetadata(customMeta)
            .build()

        val artworkUrl = parsedMetadata?.artworkUrl
        playbackService?.clearArtworkCache()

        mainHandler.post {
            val service = playbackService
            val player = service?.getPlayer() ?: run {
                onRejected?.invoke("Playback service is not ready")
                return@post
            }
            service.isTransitioning = true
            player.stop()
            player.clearMediaItems()
            player.setMediaItem(mediaItem)
            player.prepare()
            if (startTime > 0.0) {
                player.seekTo((startTime * 1000).toLong())
            }
            emitPlaybackState("loading", requestId)
            if (autoplay) {
                requestAudioFocus()
                player.play()
            }
            service.loadAndCacheArtwork(artworkUrl)
            onResolved()
        }
    }

    @PluginMethod
    fun play(call: PluginCall) {
        checkAndRequestNotificationPermission(call) {
            executePlay(call)
        }
    }

    private fun executePlay(call: PluginCall) {
        NativeLogger.debug("Play requested", "audio-plugin")
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val player = service.getPlayer() ?: run {
                        call.reject("ExoPlayer is not ready")
                        return@post
                    }

                    service.savedRestoreTime = null
                    service.queueEngine.clearRestoredFlag()

                    requestAudioFocus()
                    player.play()
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun pause(call: PluginCall) {
        NativeLogger.debug("Pause requested", "audio-plugin")
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val player = service.getPlayer() ?: run {
                        call.reject("ExoPlayer is not ready")
                        return@post
                    }
                    player.pause()
                    service.persistence.flushNow()
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun stop(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val player = service.getPlayer() ?: run {
                        call.reject("ExoPlayer is not ready")
                        return@post
                    }
                    player.pause()
                    player.seekTo(0)
                    emitPlaybackState("stopped", currentRequestId)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun seek(call: PluginCall) {
        val position = call.getDouble("position") ?: run {
            call.reject("Missing position parameter")
            return
        }
        NativeLogger.debug("Seek to $position", "audio-plugin")
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val player = service.getPlayer() ?: run {
                        call.reject("ExoPlayer is not ready")
                        return@post
                    }
                    player.seekTo((position * 1000).toLong())
                    service.persistence.updateProgress(position)
                    service.persistence.flushNow()
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun updateMetadata(call: PluginCall) {
        val title = call.getString("title")
        val artist = call.getString("artist")
        val album = call.getString("album")
        val artworkUrl = call.getString("artworkUrl")

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val player = service.getPlayer() ?: run {
                        call.reject("ExoPlayer is not ready")
                        return@post
                    }
                    val currentItem = player.currentMediaItem
                    if (currentItem != null) {
                        val updatedMetadata = currentItem.mediaMetadata.buildUpon()
                            .setTitle(title)
                            .setArtist(artist)
                            .setAlbumTitle(album)
                        if (artworkUrl != null) {
                            updatedMetadata.setArtworkUri(Uri.parse(artworkUrl))
                        }
                        val updatedMeta = updatedMetadata.build()
                        service.currentSongMetadata = updatedMeta
                        val updatedItem = currentItem.buildUpon()
                            .setMediaMetadata(updatedMeta)
                            .build()
                        player.replaceMediaItem(player.currentMediaItemIndex, updatedItem)
                    }
                    service.updateNotification()
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun updateRemotePlaybackState(call: PluginCall) {
        val metadataObject = call.getObject("metadata")
        val title = metadataObject?.getString("title")
        val artist = metadataObject?.getString("artist")
        val album = metadataObject?.getString("album")
        val artworkUrl = metadataObject?.getString("artworkUrl")
        val coverArtId = metadataObject?.getString("coverArtId")
        val duration = call.getDouble("duration") ?: metadataObject?.optDouble("duration", 0.0) ?: 0.0
        val position = call.getDouble("position") ?: 0.0
        val isPlaying = call.getBoolean("isPlaying") ?: false
        val isShuffleActive = call.getBoolean("isShuffleActive") ?: false
        val repeatMode = call.getString("repeatMode") ?: "off"
        val volume = call.getDouble("volume")
        val targetDeviceId = call.getString("targetDeviceId")
        val expectedGeneration = call.getInt("expectedGeneration")

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val metadataBuilder = MediaMetadata.Builder()
                        .setTitle(title)
                        .setArtist(artist)
                        .setAlbumTitle(album)
                    if (duration > 0) {
                        metadataBuilder.setDurationMs((duration * 1000).toLong())
                    }
                    if (artworkUrl != null) {
                        metadataBuilder.setArtworkUri(Uri.parse(artworkUrl))
                    }
                    service.updateRemotePlaybackProjection(
                        metadataBuilder.build(),
                        isPlaying,
                        position,
                        duration,
                        isShuffleActive,
                        repeatMode,
                        volume,
                        artworkUrl,
                        coverArtId,
                        targetDeviceId,
                        expectedGeneration,
                    )
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun clearRemotePlaybackState(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.clearRemotePlaybackProjection()
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun clear(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val player = service.getPlayer() ?: run {
                        call.resolve()
                        return@post
                    }
                    player.stop()
                    player.clearMediaItems()
                    emitPlaybackState("idle", currentRequestId)
                    currentRequestId = null
                    service.handleScrobbleSongEnded()
                    abandonAudioFocus()
                    service.clearQueueState()
                    service.currentSongMetadata = null
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    private fun deleteCachedAudioFileInternal(songId: String): Boolean {
        val cacheId = AudioCacheUtils.cacheId(songId)
        var deleted = false
        val cacheDirs = listOf(
            AudioCacheDirectoryHelper.getCacheDir(context),
            AudioCacheDirectoryHelper.getSecCacheDir(context)
        )
        for (dir in cacheDirs) {
            if (dir.exists() && dir.isDirectory) {
                val files = dir.listFiles()
                if (files != null) {
                    for (file in files) {
                        if (file.name.startsWith("$cacheId.")) {
                            if (file.delete()) {
                                deleted = true
                            }
                        }
                    }
                }
            }
        }
        return deleted
    }

    private fun resolveCachedAudioFileInternal(songId: String): JSObject? {
        val cacheId = AudioCacheUtils.cacheId(songId)
        val cacheDirs = listOf(
            AudioCacheDirectoryHelper.getCacheDir(context),
            AudioCacheDirectoryHelper.getSecCacheDir(context)
        )

        for (dir in cacheDirs) {
            if (!dir.exists() || !dir.isDirectory) continue
            val metadataFile = File(dir, "$cacheId.json")
            if (metadataFile.exists()) {
                try {
                    val json = JSONObject(metadataFile.readText(Charsets.UTF_8))
                    val fileName = json.getString("fileName")
                    val contentType = json.getString("contentType")
                    val lastModifiedAt = json.getDouble("lastModifiedAt")

                    val audioFile = File(dir, fileName)
                    if (audioFile.exists()) {
                        return JSObject().apply {
                            put("songId", songId)
                            put("uri", Uri.fromFile(audioFile).toString())
                            put("contentType", contentType)
                            put("sizeBytes", audioFile.length())
                            put("lastModifiedAt", lastModifiedAt)
                        }
                    }
                } catch (_: Exception) {
                }
            }

            val files = dir.listFiles()
            if (files != null) {
                for (file in files) {
                    if (file.name.startsWith("$cacheId.") && !file.name.endsWith(".json")) {
                        return JSObject().apply {
                            put("songId", songId)
                            put("uri", Uri.fromFile(file).toString())
                            put("contentType", "audio/mpeg")
                            put("sizeBytes", file.length())
                            put("lastModifiedAt", file.lastModified().toDouble())
                        }
                    }
                }
            }
        }
        return null
    }

    private object AudioCacheDirectoryHelper {
        fun getCacheDir(context: Context) = AudioCacheUtils.getCacheDirectory(context)
        fun getSecCacheDir(context: Context) = AudioCacheUtils.getSecondaryCacheDirectory(context)
    }

    @PluginMethod
    fun resolveAudioFile(call: PluginCall) {
        val songId = call.getString("songId") ?: run {
            call.reject("Missing songId")
            return
        }

        pluginScope.launch(Dispatchers.IO) {
            try {
                val file = resolveCachedAudioFileInternal(songId)
                val response = JSObject().apply {
                    if (file != null) {
                        put("file", file)
                    } else {
                        put("file", JSONObject.NULL)
                    }
                }
                call.resolve(response)
            } catch (e: Exception) {
                call.reject("Failed to resolve audio file: ${e.localizedMessage}")
            }
        }
    }

    @PluginMethod
    fun getAudioFileSize(call: PluginCall) {
        val songId = call.getString("songId") ?: run {
            call.reject("Missing songId")
            return
        }

        pluginScope.launch(Dispatchers.IO) {
            val file = resolveCachedAudioFileInternal(songId)
            val response = JSObject().apply {
                if (file != null) {
                    put("sizeBytes", file.getLong("sizeBytes"))
                } else {
                    put("sizeBytes", JSONObject.NULL)
                }
            }
            call.resolve(response)
        }
    }

    @PluginMethod
    fun deleteAudioFile(call: PluginCall) {
        val songId = call.getString("songId") ?: run {
            call.reject("Missing songId")
            return
        }

        pluginScope.launch(Dispatchers.IO) {
            val deleted = deleteCachedAudioFileInternal(songId)
            val response = JSObject().apply {
                put("deleted", deleted)
            }
            call.resolve(response)
        }
    }

    @PluginMethod
    fun clearAudioFiles(call: PluginCall) {
        pluginScope.launch(Dispatchers.IO) {
            var count = 0
            val cacheDirs = listOf(
                AudioCacheDirectoryHelper.getCacheDir(context),
                AudioCacheDirectoryHelper.getSecCacheDir(context)
            )
            for (dir in cacheDirs) {
                if (dir.exists() && dir.isDirectory) {
                    val files = dir.listFiles()
                    if (files != null) {
                        for (file in files) {
                            if (file.delete()) {
                                count++
                            }
                        }
                    }
                }
            }
            val response = JSObject().apply {
                put("deletedCount", count)
            }
            call.resolve(response)
        }
    }

    @PluginMethod
    fun setVolumeHUDEnabled(call: PluginCall) {
        val enabled = call.getBoolean("enabled", true) ?: true
        isVolumeHUDDisabled = !enabled
        call.resolve()
    }

    @PluginMethod
    fun getScrobbleBuffer(call: PluginCall) {
        val service = playbackService
        if (service == null) {
            call.resolve(JSObject().apply {
                put("entries", JSONArray())
            })
            return
        }
        val entries = service.scrobbleBuffer.getEntries()
        val array = JSONArray()
        for (entry in entries) {
            array.put(JSONObject().apply {
                put("songId", entry.songId)
                put("playedDurationMs", entry.playedDurationMs)
                put("timestamp", entry.timestamp)
            })
        }
        call.resolve(JSObject().apply {
            put("entries", array)
        })
    }

    @PluginMethod
    fun clearScrobbleBuffer(call: PluginCall) {
        playbackService?.scrobbleBuffer?.clear()
        call.resolve()
    }

    // MARK: - Queue Engine Methods

    @PluginMethod
    fun setContextQueue(call: PluginCall) {
        NativeLogger.debug("Setting context queue", "audio-plugin")
        val songsArray = call.getArray("songs") ?: run {
            call.reject("Missing songs parameter")
            return
        }
        val songs = mutableListOf<QueueSong>()
        for (i in 0 until songsArray.length()) {
            songs.add(QueueSong.from(songsArray.getJSONObject(i)))
        }

        val currentIndex = call.getInt("currentIndex") ?: 0
        val autoplay = call.getBoolean("autoplay", true) ?: true
        val startTime = call.getDouble("startTime")

        var sourceId: QueueSourceId? = null
        val srcObj = call.getObject("sourceId")
        if (srcObj != null) {
            sourceId = QueueSourceId.from(srcObj)
        }
        val sourceName = call.getString("sourceName")

        val repeatMode = call.getString("repeatMode")

        pluginScope.launch {
            try {
                val service = awaitService()
                // Set isQueueEngineActive early to prevent a concurrent load()
                // call (triggered by Zustand → React re-render → src change →
                // backend.load()) from also playing on the same ExoPlayer.
                // Otherwise both loadMediaAndPlay() and loadSong() conflict.
                service.isQueueEngineActive = true
                mainHandler.post {
                    repeatMode?.let { service.setRepeatMode(it) }
                    service.setContextQueue(songs, currentIndex, autoplay, startTime, sourceId, sourceName)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun updateContextQueue(call: PluginCall) {
        val songsArray = call.getArray("songs") ?: run {
            call.reject("Missing songs parameter")
            return
        }
        val songs = mutableListOf<QueueSong>()
        for (i in 0 until songsArray.length()) {
            songs.add(QueueSong.from(songsArray.getJSONObject(i)))
        }
        val currentIndex = call.getInt("currentIndex") ?: 0

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.updateContextQueue(songs, currentIndex)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun reorderContextQueue(call: PluginCall) {
        val fromIndex = call.getInt("fromIndex") ?: 0
        val toIndex = call.getInt("toIndex") ?: 0

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.reorderContextQueue(fromIndex, toIndex)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun addToUserQueue(call: PluginCall) {
        val songsArray = call.getArray("songs") ?: run {
            call.reject("Missing songs parameter")
            return
        }
        val songs = mutableListOf<QueueSong>()
        for (i in 0 until songsArray.length()) {
            songs.add(QueueSong.from(songsArray.getJSONObject(i)))
        }
        val position = call.getString("position") ?: "last"

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.addToUserQueue(songs, position)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun removeFromUserQueue(call: PluginCall) {
        val indicesArray = call.getArray("indices") ?: run {
            call.reject("Missing indices parameter")
            return
        }
        val indices = mutableListOf<Int>()
        for (i in 0 until indicesArray.length()) {
            indices.add(indicesArray.getInt(i))
        }

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.removeFromUserQueue(indices)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun clearUserQueue(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.clearUserQueue()
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun playAtIndex(call: PluginCall) {
        val index = call.getInt("index") ?: 0
        val startTime = call.getDouble("startTime")

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.playAtIndex(index, startTime)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun getFullState(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    val player = service.getPlayer()
                    val currentTime = if (player != null) player.currentPosition / 1000.0 else 0.0
                    val duration = if (player != null && player.duration != C.TIME_UNSET) player.duration / 1000.0 else 0.0
                    val isPlaying = if (player != null) player.isPlaying else false

                    val fullState = service.queueEngine.getFullState(currentTime, duration, isPlaying)
                    val jsObj = JSObject.fromJSONObject(fullState)
                    call.resolve(jsObj)
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun setRepeatMode(call: PluginCall) {
        val mode = call.getString("mode") ?: "off"

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.setRepeatMode(mode)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun setShuffle(call: PluginCall) {
        val enabled = call.getBoolean("enabled") ?: false

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.setShuffle(enabled)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun markAsShuffled(call: PluginCall) {
        val songsArray = call.getArray("originalSongs") ?: run {
            call.reject("Missing originalSongs parameter")
            return
        }
        val songs = mutableListOf<QueueSong>()
        for (i in 0 until songsArray.length()) {
            songs.add(QueueSong.from(songsArray.getJSONObject(i)))
        }

        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.markAsShuffled(songs)
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun skipToNext(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    if (service.isQueueEngineActive) {
                        service.queueEngine.skipToNext()
                    } else {
                        emitRemoteCommand("next")
                    }
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun skipToPrevious(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    if (service.isQueueEngineActive) {
                        val player = service.getPlayer()
                        val currentTime = if (player != null) player.currentPosition / 1000.0 else 0.0
                        service.queueEngine.skipToPrevious(currentTime)
                    } else {
                        emitRemoteCommand("previous")
                    }
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun preload(call: PluginCall) {
        call.resolve()
    }

    @PluginMethod
    fun storeAudioFile(call: PluginCall) {
        val songId = call.getString("songId") ?: run {
            call.reject("Missing songId")
            return
        }
        val dataBase64 = call.getString("dataBase64") ?: run {
            call.reject("Missing dataBase64")
            return
        }
        val contentType = call.getString("contentType") ?: "audio/mpeg"

        pluginScope.launch(Dispatchers.IO) {
            try {
                val data = android.util.Base64.decode(dataBase64, android.util.Base64.DEFAULT)
                val cacheDir = AudioCacheUtils.getCacheDirectory(context, createIfNeeded = true)

                deleteCachedAudioFileInternal(songId)

                val ext = AudioCacheUtils.fileExtension(contentType)
                val cacheId = AudioCacheUtils.cacheId(songId)
                val destFile = File(cacheDir, "$cacheId.$ext")
                destFile.writeBytes(data)

                val metadataFile = AudioCacheUtils.getMetadataFile(context, songId)
                val metadataJson = JSONObject().apply {
                    put("songId", songId)
                    put("fileName", destFile.name)
                    put("contentType", contentType)
                    put("lastModifiedAt", System.currentTimeMillis().toDouble())
                }
                metadataFile.writeText(metadataJson.toString(), Charsets.UTF_8)

                val response = JSObject().apply {
                    put("songId", songId)
                    put("uri", Uri.fromFile(destFile).toString())
                    put("contentType", contentType)
                    put("sizeBytes", destFile.length())
                    put("lastModifiedAt", metadataJson.getDouble("lastModifiedAt"))
                }
                call.resolve(response)
            } catch (e: Exception) {
                call.reject("Failed to store audio file: ${e.localizedMessage}")
            }
        }
    }

    @PluginMethod
    fun downloadAudioFile(call: PluginCall) {
        val songId = call.getString("songId") ?: run {
            call.reject("Missing songId")
            return
        }
        val maxBitRate = call.getInt("maxBitRate")
        val format = call.getString("format")

        pluginScope.launch {
            try {
                val service = awaitService()
                service.downloadManager.download(songId, maxBitRate, format)
                call.resolve()
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun cancelDownload(call: PluginCall) {
        pluginScope.launch {
            try {
                val service = awaitService()
                val songId = call.getString("songId")
                if (songId != null) {
                    service.downloadManager.cancel(songId)
                } else {
                    service.downloadManager.cancelAll()
                }
                call.resolve()
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service not ready (timeout)")
            }
        }
    }

    @PluginMethod
    fun setSystemVolume(call: PluginCall) {
        val value = call.getDouble("value") ?: run {
            call.reject("Missing value parameter")
            return
        }
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val targetVolume = (value * max).toInt()
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, targetVolume, 0)

        val actualVolume = getSystemVolumePercentage()
        call.resolve(JSObject().apply {
            put("volume", actualVolume)
        })
    }

    @PluginMethod
    fun getSystemVolume(call: PluginCall) {
        val actualVolume = getSystemVolumePercentage()
        call.resolve(JSObject().apply {
            put("volume", actualVolume)
        })
    }

    @PluginMethod
    fun resolveSongs(call: PluginCall) {
        val idsArray = call.getArray("ids") ?: run {
            call.resolve(JSObject().apply { put("songs", JSONArray()) })
            return
        }
        val ids = mutableListOf<String>()
        for (i in 0 until idsArray.length()) {
            ids.add(idsArray.getString(i))
        }
        if (ids.isEmpty()) {
            call.resolve(JSObject().apply { put("songs", JSONArray()) })
            return
        }

        pluginScope.launch {
            try {
                val records = withContext(Dispatchers.IO) {
                    db.songDao().getByIds(ids)
                }
                val songsArray = JSONArray()
                for (record in records) {
                    songsArray.put(record.toJSObject())
                }
                call.resolve(JSObject().apply { put("songs", songsArray) })
            } catch (e: Exception) {
                NativeLogger.error("resolveSongs failed: ${e.localizedMessage}", pluginName)
                call.resolve(JSObject().apply { put("songs", JSONArray()) })
            }
        }
    }

    @PluginMethod
    fun setLikeActive(call: PluginCall) {
        val active = call.getBoolean("active", false) ?: false
        pluginScope.launch {
            try {
                val service = awaitService()
                mainHandler.post {
                    service.isLikeActive = active
                    call.resolve()
                }
            } catch (_: TimeoutCancellationException) {
                call.reject("Playback service is not ready (timeout)")
            }
        }
    }

    companion object {
        @JvmStatic
        var isVolumeHUDDisabled: Boolean = false
    }
}
