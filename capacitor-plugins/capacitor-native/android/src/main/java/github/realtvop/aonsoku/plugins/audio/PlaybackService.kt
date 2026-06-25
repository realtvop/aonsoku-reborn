package github.realtvop.aonsoku.plugins.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Binder
import android.content.pm.PackageManager
import android.os.Build
import android.Manifest
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.annotation.OptIn
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import android.os.Bundle
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import github.realtvop.aonsoku.plugins.debug.NativeLogger
import github.realtvop.aonsoku.plugins.preferences.NativePreferencesStore
import github.realtvop.aonsoku.plugins.bridge.AndroidCredentialStore
import github.realtvop.aonsoku.plugins.bridge.SubsonicHttpClient
import github.realtvop.aonsoku.plugins.data.db.AonsokuDatabase
import github.realtvop.aonsoku.plugins.data.image.ImageCacheManager
import github.realtvop.aonsoku.plugins.coordination.AonsokuNativeCoordinationPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

class PlaybackService : MediaSessionService() {
    companion object {
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "aonsoku_playback"

        const val ACTION_PLAY_PAUSE = "github.realtvop.aonsoku.action.PLAY_PAUSE"
        const val ACTION_SKIP_NEXT = "github.realtvop.aonsoku.action.SKIP_NEXT"
        const val ACTION_SKIP_PREV = "github.realtvop.aonsoku.action.SKIP_PREV"
        const val ACTION_STOP = "github.realtvop.aonsoku.action.STOP"
        const val ACTION_TOGGLE_SHUFFLE = "github.realtvop.aonsoku.action.TOGGLE_SHUFFLE"
        const val ACTION_TOGGLE_LIKE = "github.realtvop.aonsoku.action.TOGGLE_LIKE"

        private const val REQUEST_CODE_CONTENT = 1000
        private const val REQUEST_CODE_PLAY_PAUSE = 1001
        private const val REQUEST_CODE_SKIP_NEXT = 1002
        private const val REQUEST_CODE_SKIP_PREV = 1003
        private const val REQUEST_CODE_STOP = 1004
        private const val REQUEST_CODE_TOGGLE_SHUFFLE = 1005
        private const val REQUEST_CODE_TOGGLE_LIKE = 1006
    }

    private var mediaSession: MediaSession? = null
    private var player: Player? = null
    private var cachedArtworkBitmap: Bitmap? = null
    private var isBoundToActivity = false

    val queueEngine = NativeQueueEngine()
    var isQueueEngineActive = false
    var savedRestoreTime: Double? = null
    var currentSongMetadata: MediaMetadata? = null
    var isRemotePlaybackProjectionActive = false
        private set
    private var remotePlaybackMetadata: MediaMetadata? = null
    private var remotePlaybackIsPlaying = false
    private var remotePlaybackPositionSeconds = 0.0
    private var remotePlaybackDurationSeconds = 0.0
    private var remotePlaybackIsShuffleActive = false
    private var remotePlaybackRepeatMode = "off"
    private var remotePlaybackVolume: Double? = null

    private val httpClient = SubsonicHttpClient()
    private val credentialStore by lazy {
        AndroidCredentialStore(this)
    }
    val scrobbleBuffer by lazy {
        NativeScrobbleBuffer(ScrobbleFileStore(this))
    }
    private val scrobbleSubmitter = NativeScrobbleSubmitter(httpClient)

    var currentScrobbleSongId: String? = null
        private set
    var currentScrobbleSongDuration: Double = 0.0
        private set

    var isLikeActive: Boolean = false
        set(value) {
            field = value
            updateNotification()
            mediaSession?.setCustomLayout(getCustomLayoutButtons())
        }
    var sleepTimerMode: String = "duration"
    var isTransitioning = false

    private val CUSTOM_COMMAND_TOGGLE_SHUFFLE by lazy {
        SessionCommand(ACTION_TOGGLE_SHUFFLE, Bundle.EMPTY)
    }
    private val CUSTOM_COMMAND_TOGGLE_LIKE by lazy {
        SessionCommand(ACTION_TOGGLE_LIKE, Bundle.EMPTY)
    }

    private fun getCustomLayoutButtons(): List<CommandButton> {
        val shuffleIconName = if (effectiveShuffleActive()) "ic_shuffle_on" else "ic_shuffle"
        val shuffleIconResId = resources.getIdentifier(shuffleIconName, "drawable", packageName)
        val shuffleIcon = if (shuffleIconResId != 0) shuffleIconResId else android.R.drawable.ic_menu_share

        val likeIconName = if (isLikeActive) "ic_favorite" else "ic_favorite_border"
        val likeIconResId = resources.getIdentifier(likeIconName, "drawable", packageName)
        val likeIcon = if (likeIconResId != 0) likeIconResId else android.R.drawable.btn_star

        android.util.Log.d("AonsokuNotification", "getCustomLayoutButtons: pkg=$packageName, shuffleName=$shuffleIconName, shuffleId=$shuffleIconResId, likeName=$likeIconName, likeId=$likeIconResId")

        val shuffleButton = CommandButton.Builder()
            .setSessionCommand(CUSTOM_COMMAND_TOGGLE_SHUFFLE)
            .setDisplayName("Shuffle")
            .setIconResId(shuffleIcon)
            .build()

        val likeButton = CommandButton.Builder()
            .setSessionCommand(CUSTOM_COMMAND_TOGGLE_LIKE)
            .setDisplayName("Like")
            .setIconResId(likeIcon)
            .build()

        return listOf(shuffleButton, likeButton)
    }

    private fun effectiveShuffleActive(): Boolean =
        if (isRemotePlaybackProjectionActive) {
            remotePlaybackIsShuffleActive
        } else {
            queueEngine.isShuffleActive
        }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val preferencesStore by lazy { NativePreferencesStore(this) }
    lateinit var persistence: PlaybackStatePersistence

    val downloadManager by lazy { NativeDownloadManager(this) }
    private val backgroundCacheSongIds = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val downloadListeners = mutableListOf<DownloadListener>()

    interface DownloadListener {
        fun onDownloadProgress(songId: String, loaded: Long, total: Long)
        fun onDownloadCompleted(songId: String, fileUri: String, contentType: String, sizeBytes: Long)
        fun onDownloadFailed(songId: String, errorMessage: String)
    }

    fun addDownloadListener(listener: DownloadListener) {
        synchronized(downloadListeners) {
            if (!downloadListeners.contains(listener)) {
                downloadListeners.add(listener)
            }
        }
    }

    fun removeDownloadListener(listener: DownloadListener) {
        synchronized(downloadListeners) {
            downloadListeners.remove(listener)
        }
    }

    fun isBackgroundCache(songId: String): Boolean = backgroundCacheSongIds.contains(songId)
    fun removeBackgroundCache(songId: String): Boolean = backgroundCacheSongIds.remove(songId)

    private fun startBackgroundCache(songId: String) {
        val cacheId = AudioCacheUtils.cacheId(songId)
        val extensions = listOf("mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "audio")

        val cacheDirectories = listOf(
            AudioCacheUtils.getCacheDirectory(this),
            AudioCacheUtils.getSecondaryCacheDirectory(this)
        )
        for (directory in cacheDirectories) {
            if (directory.exists() && directory.isDirectory) {
                for (ext in extensions) {
                    if (File(directory, "$cacheId.$ext").exists()) {
                        return
                    }
                }
            }
        }

        backgroundCacheSongIds.add(songId)
        downloadManager.download(songId)
    }

    interface Listener {
        fun onRemoteCommand(command: String, position: Double?)
        fun onQueueStateChanged(currentIndex: Int, songId: String, reason: String, isInUserQueue: Boolean)
        fun onQueueContentsChanged(reason: String)
        fun onPlaybackStateChanged(state: String)
        fun onEnded(reason: String)
        fun onSleepTimerEndOfTrack()
        fun onError(code: String, message: String)
    }

    private val listeners = mutableListOf<Listener>()

    fun addListener(listener: Listener) {
        if (!listeners.contains(listener)) {
            listeners.add(listener)
        }
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    private fun emitRemoteCommand(command: String, position: Double? = null) {
        listeners.forEach { it.onRemoteCommand(command, position) }
    }

    private fun emitQueueStateChanged(currentIndex: Int, songId: String, reason: String, isInUserQueue: Boolean) {
        listeners.forEach { it.onQueueStateChanged(currentIndex, songId, reason, isInUserQueue) }
    }

    private fun emitQueueContentsChanged(reason: String) {
        listeners.forEach { it.onQueueContentsChanged(reason) }
    }

    private fun emitPlaybackState(state: String) {
        listeners.forEach { it.onPlaybackStateChanged(state) }
    }

    private fun emitEnded(reason: String) {
        listeners.forEach { it.onEnded(reason) }
    }

    private fun emitSleepTimerEndOfTrack() {
        listeners.forEach { it.onSleepTimerEndOfTrack() }
    }

    private fun emitError(code: String, message: String) {
        listeners.forEach { it.onError(code, message) }
    }

    fun handleScrobbleSongEnded() {
        val entry = scrobbleBuffer.stopTracking()
        if (entry != null) {
            val credentials = credentialStore.retrieve()
            if (credentials != null) {
                scrobbleSubmitter.submitIfEligible(entry, currentScrobbleSongDuration, credentials, scrobbleBuffer)
            }
        }
        currentScrobbleSongId = null
    }

    fun handleScrobbleSongStarted(songId: String, duration: Double) {
        currentScrobbleSongId = songId
        currentScrobbleSongDuration = duration
        scrobbleBuffer.startTracking(songId, duration)
        val credentials = credentialStore.retrieve()
        if (credentials != null) {
            serviceScope.launch {
                scrobbleSubmitter.sendNowPlaying(songId, credentials)
            }
        }
    }

    fun submitPendingScrobbles() {
        val credentials = credentialStore.retrieve()
        if (credentials != null) {
            CoroutineScope(Dispatchers.IO).launch {
                scrobbleSubmitter.submitPending(scrobbleBuffer, credentials)
            }
        }
    }

    inner class LocalBinder : Binder() {
        fun getService(): PlaybackService = this@PlaybackService
    }

    private val binder = LocalBinder()

    fun getPlayer(): Player? = player
    fun getSession(): MediaSession? = mediaSession

    @OptIn(UnstableApi::class)
    override fun onCreate() {
        super.onCreate()
        NativeLogger.info("PlaybackService created", "playback-service")

        createNotificationChannel()

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()

        val renderersFactory = DefaultRenderersFactory(this)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)

        val basePlayer = ExoPlayer.Builder(this)
            .setRenderersFactory(renderersFactory)
            .setAudioAttributes(audioAttributes, true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()

        // Force skip commands so notification action buttons are always visible.
        // ExoPlayer only advertises COMMAND_SEEK_TO_NEXT / _PREVIOUS when the
        // timeline has more than one item; without them, the system may hide
        // the action buttons added to the MediaStyle notification.
        player = object : ForwardingPlayer(basePlayer) {
            override fun getAvailableCommands(): Player.Commands {
                return super.getAvailableCommands().buildUpon()
                    .add(COMMAND_SEEK_TO_NEXT)
                    .add(COMMAND_SEEK_TO_PREVIOUS)
                    .add(COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                    .add(COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                    .add(COMMAND_SET_SHUFFLE_MODE)
                    .add(COMMAND_SET_REPEAT_MODE)
                    .build()
            }

            override fun getMediaMetadata(): MediaMetadata {
                return remotePlaybackMetadata
                    ?: currentSongMetadata
                    ?: super.getMediaMetadata()
            }
        }

        persistence = PlaybackStatePersistence(preferencesStore, serviceScope).apply {
            setStateProvider {
                val currentPlayer = player ?: return@setStateProvider null
                val progressSec = currentPlayer.currentPosition / 1000.0
                PlaybackPersistState.from(queueEngine, progressSec)
            }
        }

        queueEngine.delegate = object : NativeQueueEngineDelegate {
            override fun queueEngineLoadSong(engine: NativeQueueEngine, song: QueueSong, autoplay: Boolean, startTime: Double?) {
                loadSong(song, autoplay, startTime)
            }

            override fun queueEngineDidAdvanceTo(engine: NativeQueueEngine, index: Int, songId: String, reason: QueueAdvanceReason) {
                persistence.markStateDirty()
                handleScrobbleSongEnded()
                val duration = engine.currentSong?.duration ?: 0.0
                handleScrobbleSongStarted(songId, duration)
                emitQueueStateChanged(index, songId, reason.value, engine.isInUserQueue)
            }

            override fun queueEngineDidChangeContents(engine: NativeQueueEngine, reason: String) {
                persistence.markStateDirty()
                emitQueueContentsChanged(reason)
            }

            override fun queueEngineDidExhaustQueue(engine: NativeQueueEngine) {
                val mainHandler = Handler(Looper.getMainLooper())
                mainHandler.post {
                    handleScrobbleSongEnded()
                    player?.pause()
                    player?.seekTo(0)
                    emitPlaybackState("ended")
                    emitEnded("finished")
                }
            }

            override fun queueEngineSeekToStart(engine: NativeQueueEngine, song: QueueSong) {
                val mainHandler = Handler(Looper.getMainLooper())
                mainHandler.post {
                    handleScrobbleSongEnded()
                    handleScrobbleSongStarted(song.id, song.duration)
                    player?.seekTo(0)
                    player?.play()
                }
            }
        }

        player?.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) {
                    if (sleepTimerMode == "endOfTrack") {
                        sleepTimerMode = "duration"
                        player?.pause()
                        emitPlaybackState("paused")
                        emitSleepTimerEndOfTrack()
                        return
                    }
                    if (isQueueEngineActive) {
                        queueEngine.handleEnded()
                    } else {
                        handleScrobbleSongEnded()
                        emitEnded("finished")
                    }
                }

                val currentPlayer = player
                if (currentPlayer != null) {
                    if (playbackState == Player.STATE_READY && !currentPlayer.playWhenReady) {
                        isTransitioning = false
                        if (!isBoundToActivity) {
                            stopForeground(STOP_FOREGROUND_REMOVE)
                            stopSelf()
                        }
                    } else if (playbackState == Player.STATE_IDLE) {
                        isTransitioning = false
                        if (!isBoundToActivity) {
                            stopForeground(STOP_FOREGROUND_REMOVE)
                            stopSelf()
                        }
                    }
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                updateNotification()
                if (isPlaying) {
                    isTransitioning = false
                    persistence.startProgressTracking()
                    if (currentScrobbleSongId != null) {
                        scrobbleBuffer.resumeTracking()
                    }
                } else {
                    persistence.stopProgressTracking()
                    persistence.flushNow()
                    if (currentScrobbleSongId != null) {
                        scrobbleBuffer.pauseTracking()
                    }

                    val isEndTransition = player?.let {
                        it.playbackState == Player.STATE_ENDED &&
                        sleepTimerMode != "endOfTrack" &&
                        isQueueEngineActive &&
                        (queueEngine.hasNext || queueEngine.loopState == LoopState.ONE)
                    } ?: false

                    if (isEndTransition) {
                        isTransitioning = true
                    }

                    if (!isTransitioning && !isBoundToActivity) {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                }
            }

            override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) {
                if (queueEngine.isShuffleActive != shuffleModeEnabled) {
                    emitRemoteCommand("shuffle")
                }
            }
        })

        val callback = object : MediaSession.Callback {
            override fun onConnect(
                session: MediaSession,
                controller: MediaSession.ControllerInfo
            ): MediaSession.ConnectionResult {
                android.util.Log.d("AonsokuNotification", "onConnect: pkg=${controller.packageName}, connectionVersion=${controller.controllerVersion}")
                val connectionResult = super.onConnect(session, controller)
                val availableSessionCommands = connectionResult.availableSessionCommands.buildUpon()
                    .add(CUSTOM_COMMAND_TOGGLE_SHUFFLE)
                    .add(CUSTOM_COMMAND_TOGGLE_LIKE)
                    .build()
                val availablePlayerCommands = connectionResult.availablePlayerCommands.buildUpon()
                    .add(Player.COMMAND_SEEK_TO_NEXT)
                    .add(Player.COMMAND_SEEK_TO_PREVIOUS)
                    .add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                    .add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                    .add(Player.COMMAND_SET_SHUFFLE_MODE)
                    .add(Player.COMMAND_SET_REPEAT_MODE)
                    .build()
                return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                    .setAvailableSessionCommands(availableSessionCommands)
                    .setAvailablePlayerCommands(availablePlayerCommands)
                    .setCustomLayout(getCustomLayoutButtons())
                    .build()
            }

            override fun onPostConnect(session: MediaSession, controller: MediaSession.ControllerInfo) {
                super.onPostConnect(session, controller)
                android.util.Log.d("AonsokuNotification", "onPostConnect: pkg=${controller.packageName}")
                session.setCustomLayout(controller, getCustomLayoutButtons())
            }

            override fun onCustomCommand(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
                customCommand: SessionCommand,
                args: Bundle
            ): ListenableFuture<SessionResult> {
                when (customCommand.customAction) {
                    ACTION_TOGGLE_SHUFFLE -> {
                        emitRemoteCommand("shuffle")
                        session.setCustomLayout(getCustomLayoutButtons())
                        return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
                    }
                    ACTION_TOGGLE_LIKE -> {
                        emitRemoteCommand("like")
                        session.setCustomLayout(getCustomLayoutButtons())
                        return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
                    }
                }
                return super.onCustomCommand(session, controller, customCommand, args)
            }

            override fun onPlayerCommandRequest(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
                playerCommand: Int
            ): Int {
                when (playerCommand) {
                    Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> {
                        if (isQueueEngineActive) {
                            queueEngine.skipToNext()
                            return SessionResult.RESULT_INFO_SKIPPED
                        }
                        emitRemoteCommand("next")
                        return SessionResult.RESULT_INFO_SKIPPED
                    }
                    Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> {
                        if (isQueueEngineActive) {
                            val currentTime = (player?.currentPosition ?: 0L) / 1000.0
                            queueEngine.skipToPrevious(currentTime)
                            return SessionResult.RESULT_INFO_SKIPPED
                        }
                        emitRemoteCommand("previous")
                        return SessionResult.RESULT_INFO_SKIPPED
                    }
                    else -> {
                        if (!isQueueEngineActive) {
                            val commandName = when (playerCommand) {
                                Player.COMMAND_PLAY_PAUSE -> "togglePlayPause"
                                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM -> "seek"
                                else -> null
                            }
                            if (commandName != null) {
                                emitRemoteCommand(commandName)
                                return SessionResult.RESULT_INFO_SKIPPED
                            }
                        }
                        return super.onPlayerCommandRequest(session, controller, playerCommand)
                    }
                }
            }
        }

        mediaSession = MediaSession.Builder(this, player!!)
            .setCallback(callback)
            .setCustomLayout(getCustomLayoutButtons())
            .build()

        showNotification()

        downloadManager.addListener(object : NativeDownloadManager.Listener {
            override fun onDownloadProgress(songId: String, loaded: Long, total: Long) {
                synchronized(downloadListeners) {
                    downloadListeners.forEach { it.onDownloadProgress(songId, loaded, total) }
                }
            }

            override fun onDownloadCompleted(songId: String, fileUri: String, contentType: String, sizeBytes: Long) {
                synchronized(downloadListeners) {
                    downloadListeners.forEach { it.onDownloadCompleted(songId, fileUri, contentType, sizeBytes) }
                }
            }

            override fun onDownloadFailed(songId: String, errorMessage: String) {
                synchronized(downloadListeners) {
                    downloadListeners.forEach { it.onDownloadFailed(songId, errorMessage) }
                }
            }
        })

        restorePlaybackState()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Playback",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Music playback controls"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
            NativeLogger.info("Notification channel created: $CHANNEL_ID", "playback-service")
        }
    }

    private fun buildNotification(isPlaying: Boolean = false): Notification {
        val session = mediaSession
        val title: String
        val text: String
        var subText: String? = null
        if (isRemotePlaybackProjectionActive && remotePlaybackMetadata != null) {
            val metadata = remotePlaybackMetadata!!
            title = metadata.title?.toString() ?: "Aonsoku"
            text = metadata.artist?.toString() ?: "Playing"
            subText = metadata.albumTitle?.toString()
        } else if (session != null) {
            val metadata = session.player.mediaMetadata
            title = metadata.title?.toString() ?: "Aonsoku"
            text = metadata.artist?.toString() ?: "Playing"
            subText = metadata.albumTitle?.toString()
        } else {
            title = "Aonsoku"
            text = "Playing"
        }

        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        } ?: Intent()
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            REQUEST_CODE_CONTENT,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = Intent(this, PlaybackService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(
            this,
            REQUEST_CODE_STOP,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val style = MediaStyle()
            .setShowActionsInCompactView(1, 2, 3)
        if (session != null) {
            style.setMediaSession(session.sessionCompatToken)
        }

        val shuffleIntent = Intent(this, PlaybackService::class.java).setAction(ACTION_TOGGLE_SHUFFLE)
        val shufflePendingIntent = PendingIntent.getService(
            this,
            REQUEST_CODE_TOGGLE_SHUFFLE,
            shuffleIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val prevIntent = Intent(this, PlaybackService::class.java).setAction(ACTION_SKIP_PREV)
        val prevPendingIntent = PendingIntent.getService(
            this,
            REQUEST_CODE_SKIP_PREV,
            prevIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val playPauseIntent = Intent(this, PlaybackService::class.java).setAction(ACTION_PLAY_PAUSE)
        val playPausePendingIntent = PendingIntent.getService(
            this,
            REQUEST_CODE_PLAY_PAUSE,
            playPauseIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val nextIntent = Intent(this, PlaybackService::class.java).setAction(ACTION_SKIP_NEXT)
        val nextPendingIntent = PendingIntent.getService(
            this,
            REQUEST_CODE_SKIP_NEXT,
            nextIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val likeIntent = Intent(this, PlaybackService::class.java).setAction(ACTION_TOGGLE_LIKE)
        val likePendingIntent = PendingIntent.getService(
            this,
            REQUEST_CODE_TOGGLE_LIKE,
            likeIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val effectiveIsPlaying =
            if (isRemotePlaybackProjectionActive) remotePlaybackIsPlaying else isPlaying
        val playPauseIcon = if (effectiveIsPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playPauseLabel = if (effectiveIsPlaying) "Pause" else "Play"

        val shuffleIconName = if (effectiveShuffleActive()) "ic_shuffle_on" else "ic_shuffle"
        val shuffleIconResId = resources.getIdentifier(shuffleIconName, "drawable", packageName)
        val shuffleIcon = if (shuffleIconResId != 0) shuffleIconResId else android.R.drawable.ic_menu_share

        val likeIconName = if (isLikeActive) "ic_favorite" else "ic_favorite_border"
        val likeIconResId = resources.getIdentifier(likeIconName, "drawable", packageName)
        val likeIcon = if (likeIconResId != 0) likeIconResId else android.R.drawable.btn_star

        val iconResId = resources.getIdentifier("icon_transparent", "drawable", packageName)
        val icon = if (iconResId != 0) iconResId else android.R.drawable.ic_menu_info_details

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(icon)
            .setLargeIcon(cachedArtworkBitmap)
            .setContentTitle(title)
            .setContentText(text)
            .setSubText(subText)
            .setContentIntent(contentPendingIntent)
            .setDeleteIntent(stopPendingIntent)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setStyle(style)
            .addAction(shuffleIcon, "Shuffle", shufflePendingIntent)
            .addAction(android.R.drawable.ic_media_previous, "Previous", prevPendingIntent)
            .addAction(playPauseIcon, playPauseLabel, playPausePendingIntent)
            .addAction(android.R.drawable.ic_media_next, "Next", nextPendingIntent)
            .addAction(likeIcon, "Like", likePendingIntent)

        return builder.build()
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private var isForegroundStarted = false

    private fun showNotification() {
        val isPlaying =
            if (isRemotePlaybackProjectionActive) remotePlaybackIsPlaying else player?.isPlaying ?: false
        val notification = buildNotification(isPlaying)
        if (!isForegroundStarted) {
            try {
                startForeground(NOTIFICATION_ID, notification)
                isForegroundStarted = true
            } catch (e: Exception) {
                NativeLogger.warn(
                    "startForeground failed, using fallback notification: ${e.message}",
                    "playback-service"
                )
                val manager = getSystemService(NotificationManager::class.java)
                try {
                    manager.notify(NOTIFICATION_ID, notification)
                } catch (_: Exception) {}
            }
        } else {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, notification)
        }
    }

    fun tryStartForeground(): Boolean {
        if (isForegroundStarted) return true
        if (!hasNotificationPermission()) return false
        val isPlaying = player?.isPlaying ?: false
        val notification = buildNotification(isPlaying)
        try {
            startForeground(NOTIFICATION_ID, notification)
            isForegroundStarted = true
            return true
        } catch (e: Exception) {
            NativeLogger.warn(
                "tryStartForeground failed: ${e.message}",
                "playback-service"
            )
            return false
        }
    }

    fun clearArtworkCache() {
        cachedArtworkBitmap = null
    }

    fun updateNotification() {
        if (player != null) {
            showNotification()
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return mediaSession
    }

    @OptIn(UnstableApi::class)
    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        val isPlaying = player?.isPlaying ?: false
        val notification = buildNotification(isPlaying)
        if (startInForegroundRequired || !isForegroundStarted) {
            try {
                startForeground(NOTIFICATION_ID, notification)
                isForegroundStarted = true
            } catch (e: Exception) {
                NativeLogger.warn(
                    "startForeground failed in onUpdateNotification: ${e.message}",
                    "playback-service"
                )
                val manager = getSystemService(NotificationManager::class.java)
                try {
                    manager.notify(NOTIFICATION_ID, notification)
                } catch (_: Exception) {}
            }
        } else {
            val manager = getSystemService(NotificationManager::class.java)
            try {
                manager.notify(NOTIFICATION_ID, notification)
            } catch (_: Exception) {}
        }
    }

    override fun onBind(intent: Intent?): IBinder? {
        if (intent?.action == SERVICE_INTERFACE || intent?.action == "android.media.browse.MediaBrowserService") {
            return super.onBind(intent)
        }
        isBoundToActivity = true
        return binder
    }

    override fun onUnbind(intent: Intent?): Boolean {
        NativeLogger.info("PlaybackService onUnbind: intent=$intent", "playback-service")
        if (intent?.action != SERVICE_INTERFACE && intent?.action != "android.media.browse.MediaBrowserService") {
            isBoundToActivity = false
            val currentPlayer = player
            if (currentPlayer == null || !currentPlayer.isPlaying) {
                persistence.stopProgressTracking()
                persistence.flushNow()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return super.onUnbind(intent)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        NativeLogger.info("PlaybackService onTaskRemoved", "playback-service")
        val currentPlayer = player
        if (currentPlayer == null || !currentPlayer.isPlaying) {
            // §2.1.8: the service is being stopped, so detach the coordination
            // socket from the foreground service. The plugin keeps the socket
            // in plugin-owned mode; it degrades gracefully and resumes on the
            // next foreground entry.
            AonsokuNativeCoordinationPlugin.detachActiveForegroundService()
            persistence.stopProgressTracking()
            persistence.flushNow()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            super.onTaskRemoved(rootIntent)
        } else {
            NativeLogger.info("PlaybackService onTaskRemoved: player is playing, keeping service alive", "playback-service")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // §2.1.8: while the foreground service is (re)starting, attach the
        // coordination WebSocket so the OS keeps the socket alive in the
        // background. No-op if the plugin is not loaded or no socket is open.
        AonsokuNativeCoordinationPlugin.attachToActiveForegroundService()
        when (intent?.action) {
            ACTION_PLAY_PAUSE -> {
                if (isRemotePlaybackProjectionActive) {
                    emitRemoteCommand("togglePlayPause")
                    updateNotification()
                    return START_STICKY
                }
                val currentPlayer = player ?: return START_STICKY
                if (currentPlayer.isPlaying) {
                    currentPlayer.pause()
                } else {
                    currentPlayer.play()
                }
                updateNotification()
            }
            ACTION_SKIP_NEXT -> {
                if (isQueueEngineActive) {
                    queueEngine.skipToNext()
                } else {
                    emitRemoteCommand("next")
                }
                updateNotification()
            }
            ACTION_SKIP_PREV -> {
                if (isQueueEngineActive) {
                    val currentTime = (player?.currentPosition ?: 0L) / 1000.0
                    queueEngine.skipToPrevious(currentTime)
                } else {
                    emitRemoteCommand("previous")
                }
                updateNotification()
            }
            ACTION_TOGGLE_SHUFFLE -> {
                emitRemoteCommand("shuffle")
            }
            ACTION_TOGGLE_LIKE -> {
                emitRemoteCommand("like")
            }
            ACTION_STOP -> {
                if (isRemotePlaybackProjectionActive) {
                    emitRemoteCommand("pause")
                    clearRemotePlaybackProjection()
                    return START_STICKY
                }
                player?.stop()
                player?.clearMediaItems()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onDestroy() {
        NativeLogger.info("PlaybackService destroyed", "playback-service")
        // §2.1.8: release the foreground-service association before teardown.
        AonsokuNativeCoordinationPlugin.detachActiveForegroundService()
        handleScrobbleSongEnded()
        CoroutineScope(Dispatchers.IO).launch {
            val credentials = credentialStore.retrieve()
            if (credentials != null) {
                scrobbleSubmitter.submitPending(scrobbleBuffer, credentials)
            }
        }
        serviceScope.cancel()
        persistence.stopProgressTracking()
        listeners.clear()
        currentSongMetadata = null
        mediaSession?.run {
            player?.release()
            release()
            mediaSession = null
        }
        player = null
        super.onDestroy()
    }

    fun loadSong(song: QueueSong, autoplay: Boolean, startTime: Double?) {
        isTransitioning = true
        NativeLogger.debug("Loading song: ${song.title} - ${song.artist} (autoplay=$autoplay)", "playback-service")
        val resolver = NativeSourceResolver(this)
        val resolved = resolver.resolveSource(song)

        if (resolved == null) {
            val isCredentialsMissing = song.streamUrl.startsWith("aonsoku-media://")
            val code = if (isCredentialsMissing) "missing_credentials" else "invalid_source"
            val message = if (isCredentialsMissing) {
                "Cannot resolve aonsoku-media://stream: no credentials for song ${song.id}"
            } else {
                "Cannot resolve source for song ${song.id}: ${song.streamUrl}"
            }
            NativeLogger.error(message, "playback-service")
            emitError(code, message)
            val mainHandler = Handler(Looper.getMainLooper())
            mainHandler.post {
                val currentPlayer = player ?: return@post
                currentPlayer.stop()
                currentPlayer.clearMediaItems()
                emitPlaybackState("failed")
            }
            return
        }

        val url = resolved.first
        val kind = resolved.second

        if (kind == "stream") {
            startBackgroundCache(song.id)
        }

        val localArtworkFile = if (!song.coverArtId.isNullOrEmpty()) {
            val dir = github.realtvop.aonsoku.plugins.data.image.ImageCacheUtils.cacheDirectory(cacheDir, false)
            val cid = github.realtvop.aonsoku.plugins.data.image.ImageCacheUtils.cacheId(song.coverArtId)
            val file = if (dir.exists()) {
                dir.listFiles { f -> f.name.startsWith("$cid.") }?.firstOrNull()
            } else null
            
            if (file != null && file.exists()) {
                file
            } else if (!song.albumId.isNullOrEmpty()) {
                val acid = github.realtvop.aonsoku.plugins.data.image.ImageCacheUtils.cacheId(song.albumId)
                val afile = dir.listFiles { f -> f.name.startsWith("$acid.") }?.firstOrNull()
                if (afile != null && afile.exists()) afile else null
            } else null
        } else null

        val artworkUrl = if (localArtworkFile != null && localArtworkFile.exists()) {
            "file://${localArtworkFile.absolutePath}"
        } else {
            resolveArtworkUrl(song)
        }

        val mediaMetadataBuilder = MediaMetadata.Builder()
            .setTitle(song.title)
            .setArtist(song.artist)
            .setAlbumTitle(song.album)
        artworkUrl?.let {
            mediaMetadataBuilder.setArtworkUri(Uri.parse(it))
        }

        val customMeta = mediaMetadataBuilder.build()
        currentSongMetadata = customMeta

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(url))
            .setMediaMetadata(customMeta)
            .build()

        cachedArtworkBitmap = null

        val mainHandler = Handler(Looper.getMainLooper())
        mainHandler.post {
            val currentPlayer = player ?: run {
                NativeLogger.error("loadSong: player is null, aborting", "playback-service")
                emitError("internal_error", "ExoPlayer not available")
                emitPlaybackState("failed")
                isTransitioning = false
                if (!isBoundToActivity) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                return@post
            }
            currentPlayer.stop()
            currentPlayer.clearMediaItems()
            currentPlayer.setMediaItem(mediaItem)
            currentPlayer.prepare()
            if (startTime != null && startTime > 0.0) {
                currentPlayer.seekTo((startTime * 1000).toLong())
            }
            if (autoplay) {
                currentPlayer.play()
            }
            showNotification()
            loadAndCacheArtwork(artworkUrl, song)
        }
    }

    private fun resolveArtworkUrl(song: QueueSong): String? {
        val coverArtId = song.coverArtId
        if (coverArtId.isNullOrEmpty()) return null
        val resolver = NativeSourceResolver(this)
        return resolver.resolveCoverArtUrl(coverArtId, 800)
    }



    fun loadAndCacheArtwork(artworkUrl: String?, song: QueueSong? = null) {
        val url = artworkUrl ?: return
        cachedArtworkBitmap = null
        serviceScope.launch(Dispatchers.IO) {
            try {
                val bitmap = if (url.startsWith("file://")) {
                    val filePath = url.substring(7)
                    BitmapFactory.decodeFile(filePath)
                } else {
                    val coverArtId = song?.coverArtId
                    val credentials = credentialStore.retrieve()
                    if (!coverArtId.isNullOrEmpty() && credentials != null) {
                        try {
                            val db = AonsokuDatabase.getInstance(this@PlaybackService)
                            val imageCacheManager = ImageCacheManager(cacheDir, db.cacheMetaDao())
                            val file = imageCacheManager.downloadCoverImage(coverArtId, "800", credentials)
                            BitmapFactory.decodeFile(file.absolutePath)
                        } catch (e: Exception) {
                            NativeLogger.warn("Failed to download and cache artwork natively: ${e.message}, falling back to direct stream", "playback-service")
                            val inputStream = java.net.URL(url).openStream()
                            val b = BitmapFactory.decodeStream(inputStream)
                            inputStream.close()
                            b
                        }
                    } else {
                        val inputStream = java.net.URL(url).openStream()
                        val b = BitmapFactory.decodeStream(inputStream)
                        inputStream.close()
                        b
                    }
                }
                if (bitmap != null) {
                    withContext(Dispatchers.Main) {
                        cachedArtworkBitmap = bitmap
                        updateNotification()
                    }
                }
            } catch (e: Exception) {
                NativeLogger.warn("Failed to load artwork: ${e.message}", "playback-service")
            }
        }
    }

    private fun restorePlaybackState() {
        serviceScope.launch(Dispatchers.IO) {
            try {
                val stateJsonStr = preferencesStore.getQueueState()
                if (!stateJsonStr.isNullOrEmpty()) {
                    val json = JSONObject(stateJsonStr)
                    val persistedState = PlaybackPersistState.fromJson(json)
                    withContext(Dispatchers.Main) {
                        queueEngine.restoreState(persistedState)
                        isQueueEngineActive = true
                        player?.shuffleModeEnabled = persistedState.isShuffleActive

                        val song = queueEngine.currentSong
                        if (song != null) {
                            savedRestoreTime = persistedState.currentTime
                            loadSong(song, autoplay = false, startTime = persistedState.currentTime)
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    fun setContextQueue(songs: List<QueueSong>, currentIndex: Int, autoplay: Boolean, startTime: Double?, sourceId: QueueSourceId?, sourceName: String?) {
        handleScrobbleSongEnded()
        isQueueEngineActive = true
        queueEngine.setContextQueue(songs, currentIndex, autoplay, startTime, sourceId, sourceName)
        player?.shuffleModeEnabled = queueEngine.isShuffleActive
        persistence.markStateDirty()
        val song = queueEngine.currentSong
        if (song != null) {
            handleScrobbleSongStarted(song.id, song.duration)
        }
    }

    fun updateContextQueue(songs: List<QueueSong>, currentIndex: Int) {
        queueEngine.updateContextQueue(songs, currentIndex)
        persistence.markStateDirty()
    }

    fun reorderContextQueue(fromIndex: Int, toIndex: Int) {
        queueEngine.reorderContextQueue(fromIndex, toIndex)
        persistence.markStateDirty()
    }

    fun addToUserQueue(songs: List<QueueSong>, position: String) {
        queueEngine.addToUserQueue(songs, position)
        persistence.markStateDirty()
    }

    fun removeFromUserQueue(indices: List<Int>) {
        queueEngine.removeFromUserQueue(indices)
        persistence.markStateDirty()
    }

    fun clearUserQueue() {
        queueEngine.clearUserQueue()
        persistence.markStateDirty()
    }

    fun playAtIndex(index: Int, startTime: Double?) {
        queueEngine.playAtIndex(index, startTime)
        persistence.markStateDirty()
    }

    fun setRepeatMode(mode: String) {
        val loopState = LoopState.fromValue(mode)
        queueEngine.setLoopState(loopState)
        persistence.markStateDirty()
    }

    fun setShuffle(enabled: Boolean) {
        queueEngine.setShuffleActive(enabled)
        player?.shuffleModeEnabled = enabled
        persistence.markStateDirty()
        updateNotification()
        mediaSession?.setCustomLayout(getCustomLayoutButtons())
    }

    fun markAsShuffled(originalSongs: List<QueueSong>) {
        queueEngine.markAsShuffled(originalSongs)
        player?.shuffleModeEnabled = true
        persistence.markStateDirty()
    }

    fun updateRemotePlaybackProjection(
        metadata: MediaMetadata,
        isPlaying: Boolean,
        position: Double,
        duration: Double,
        isShuffleActive: Boolean,
        repeatMode: String,
        volume: Double?
    ) {
        isRemotePlaybackProjectionActive = true
        remotePlaybackMetadata = metadata
        remotePlaybackIsPlaying = isPlaying
        remotePlaybackPositionSeconds = position.coerceAtLeast(0.0)
        remotePlaybackDurationSeconds = duration.coerceAtLeast(0.0)
        remotePlaybackIsShuffleActive = isShuffleActive
        remotePlaybackRepeatMode = repeatMode
        remotePlaybackVolume = volume
        currentSongMetadata = metadata
        updateNotification()
        mediaSession?.setCustomLayout(getCustomLayoutButtons())
    }

    fun clearRemotePlaybackProjection() {
        if (!isRemotePlaybackProjectionActive) return
        isRemotePlaybackProjectionActive = false
        remotePlaybackMetadata = null
        remotePlaybackIsPlaying = false
        remotePlaybackPositionSeconds = 0.0
        remotePlaybackDurationSeconds = 0.0
        remotePlaybackIsShuffleActive = false
        remotePlaybackRepeatMode = "off"
        remotePlaybackVolume = null
        currentSongMetadata = null
        if (player?.isPlaying == true || isQueueEngineActive) {
            updateNotification()
            return
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        isForegroundStarted = false
        val manager = getSystemService(NotificationManager::class.java)
        manager.cancel(NOTIFICATION_ID)
    }

    fun clearQueueState() {
        isQueueEngineActive = false
        queueEngine.setContextQueue(emptyList(), 0, false, null, null, null)
        player?.shuffleModeEnabled = false
        persistence.stopProgressTracking()
        currentSongMetadata = null
        serviceScope.launch(Dispatchers.IO) {
            preferencesStore.setQueueState("")
        }
    }
}
