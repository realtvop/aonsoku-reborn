package github.realtvop.aonsoku.player

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import android.util.LruCache
import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.api.SubsonicApi
import github.realtvop.aonsoku.data.coordination.PlaybackSnapshot
import github.realtvop.aonsoku.data.coordination.RemoteCommand
import github.realtvop.aonsoku.data.formatIsoTimestamp
import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.data.toQueueSong
import github.realtvop.aonsoku.data.toSong
import github.realtvop.aonsoku.i18n.Translations
import github.realtvop.aonsoku.plugins.audio.AudioCommand
import github.realtvop.aonsoku.plugins.audio.AudioCommandResult
import github.realtvop.aonsoku.plugins.audio.AudioEvent
import github.realtvop.aonsoku.plugins.audio.AudioPlaybackSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioQueueSnapshot
import github.realtvop.aonsoku.plugins.audio.PlaybackService
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.plugins.audio.QueueSourceId
import github.realtvop.aonsoku.plugins.audio.ReplayGainConfig
import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import github.realtvop.aonsoku.settings.ReplayGainSettings
import github.realtvop.aonsoku.settings.ReplayGainType
import github.realtvop.aonsoku.settings.SettingsRepository
import github.realtvop.aonsoku.ui.components.Toaster
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * UI-facing owner of playback. It binds the native [PlaybackService], mirrors
 * its typed state into flows, and turns user intent into `AudioCommand`s while
 * applying the queue rules of the web player (context queue starting at the
 * current song, user queue, replacement confirmation, shuffle/repeat rebuilds).
 *
 * While another device is under remote control ([showRemote]), [state],
 * [progress], and [volume] describe that device and the same intents become
 * [RemoteCommand]s for it, as in the web player store; [local] still describes
 * this device, which stays paused.
 */
class PlayerController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val settings: SettingsRepository,
    private val library: LibraryRepository,
    private val preferences: PreferencesService,
    private val toaster: Toaster,
    private val strings: () -> Translations,
) {
    // What the playback service reports.
    private val _local = MutableStateFlow(PlayerState())
    private val _localProgress = MutableStateFlow(PlaybackProgress())
    private val _localVolume = MutableStateFlow(1.0)

    // What the screens show: the local playback, or the device under remote control.
    private val _state = MutableStateFlow(PlayerState())
    private val _progress = MutableStateFlow(PlaybackProgress())
    private val _volume = MutableStateFlow(1.0)
    private val _remote = MutableStateFlow<RemotePlayback?>(null)
    private val _sleepTimer = MutableStateFlow(SleepTimerState())
    private val _pendingReplacement = MutableStateFlow<ReplacementRequest?>(null)
    private val _historyVersion = MutableStateFlow(0)

    val state: StateFlow<PlayerState> = _state.asStateFlow()
    val progress: StateFlow<PlaybackProgress> = _progress.asStateFlow()
    val volume: StateFlow<Double> = _volume.asStateFlow()

    /** The playback of this device, also while another one is controlled. */
    val local: StateFlow<PlayerState> = _local.asStateFlow()

    /** The device under remote control, if any. */
    val remote: StateFlow<RemotePlayback?> = _remote.asStateFlow()
    val sleepTimer: StateFlow<SleepTimerState> = _sleepTimer.asStateFlow()
    val pendingReplacement: StateFlow<ReplacementRequest?> = _pendingReplacement.asStateFlow()

    /** Bumped whenever the play history changes. */
    val historyVersion: StateFlow<Int> = _historyVersion.asStateFlow()

    private var service: PlaybackService? = null
    private var serviceJob: Job? = null
    private var bindRequested = false

    /** Full list the context queue was started from, in its original order. */
    private var sourceSongs: List<QueueSong> = emptyList()
    private var radioList: List<Radio> = emptyList()
    private var shuffleStartHistory: List<String> = emptyList()
    private val knownSongs = LruCache<String, Song>(KNOWN_SONGS_CAPACITY)
    private var tracked: TrackedPlay? = null

    private var remoteSend: ((RemoteCommand) -> Unit)? = null
    private var remoteTicker: Job? = null
    private var remoteLookup: Job? = null

    /** Songs of the remote queue that were found, and those that could not be. */
    private val remoteSongs = HashMap<String, Song>()
    private val unknownRemoteSongs = HashSet<String>()

    /**
     * Likes toggled here for songs of the controlled device. Snapshots do not
     * say what is liked, and the library here learns it at its next sync.
     */
    private val remoteLikes = HashMap<String, Boolean>()

    init {
        scope.launch {
            settings.state.map { it.playHistoryMaxSize }.distinctUntilChanged().collect {
                trimPlayHistory(it)
            }
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val bound = (binder as? PlaybackService.LocalBinder)?.getService() ?: return
            attach(bound)
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            detach()
        }
    }

    // region Connection

    /** Starts and binds the playback service; safe to call repeatedly. */
    fun connect() {
        if (bindRequested) return
        bindRequested = true
        val intent = Intent(context, PlaybackService::class.java)
        runCatching { context.startService(intent) }
        context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
    }

    /** Stops playback and releases the service, for example on sign-out. */
    fun shutdown() {
        hideRemote()
        clearLocal()
        if (bindRequested) {
            runCatching { context.unbindService(connection) }
            bindRequested = false
        }
        detach()
    }

    private fun attach(bound: PlaybackService) {
        serviceJob?.cancel()
        service = bound
        seedSourceSongs(bound)
        restoreSleepTimer(bound)
        serviceJob = scope.launch {
            launch { bound.playbackState.collect(::onPlayback) }
            launch { bound.queueState.collect(::onQueue) }
            launch { bound.events.collect(::onEvent) }
            launch {
                settings.state.map { it.replayGain }.distinctUntilChanged().collect {
                    bound.setReplayGain(it.toConfig())
                }
            }
        }
    }

    private fun detach() {
        serviceJob?.cancel()
        serviceJob = null
        service = null
        updateLocal { PlayerState() }
        setLocalProgress(PlaybackProgress())
        _sleepTimer.value = SleepTimerState()
        if (_remote.value == null) _pendingReplacement.value = null
        sourceSongs = emptyList()
        tracked = null
    }

    /** After a restart the engine still knows the pre-shuffle order. */
    private fun seedSourceSongs(bound: PlaybackService) {
        val original = bound.getFullState()?.optJSONArray("originalContextSongs") ?: return
        sourceSongs = (0 until original.length()).mapNotNull { index ->
            original.optJSONObject(index)?.let(QueueSong::from)
        }
    }

    private fun restoreSleepTimer(bound: PlaybackService) {
        val remaining = bound.getSleepTimerRemaining()
        _sleepTimer.value = when {
            remaining > 0 -> SleepTimerState(
                active = true,
                endsAtMillis = System.currentTimeMillis() + (remaining * 1000).toLong(),
            )
            bound.getSleepTimerMode() == "endOfTrack" ->
                SleepTimerState(active = true, endOfTrack = true)
            else -> SleepTimerState()
        }
    }

    // endregion

    // region Service state

    private fun onPlayback(snapshot: AudioPlaybackSnapshot) {
        val radioId = snapshot.radioId
        val current = _local.value
        val duration = snapshot.durationSeconds.takeIf { it > 0 }
            ?: current.current?.duration?.takeIf { radioId == null }
            ?: 0.0
        setLocalProgress(
            PlaybackProgress(
                position = snapshot.currentTimeSeconds.coerceAtLeast(0.0),
                duration = duration,
                buffered = snapshot.bufferedTimeSeconds,
            ),
        )
        setLocalVolume(snapshot.volume)
        updateLocal { state ->
            state.copy(
                isPlaying = snapshot.isPlaying,
                isLoading = snapshot.isBuffering || snapshot.state == "loading",
                mediaType = if (radioId != null) MediaType.Radio else MediaType.Song,
                radio = if (radioId != null) {
                    state.radio?.takeIf { it.id == radioId }
                        ?: radioList.firstOrNull { it.id == radioId }
                } else {
                    null
                },
            )
        }
        updateHistoryTracking()
    }

    private fun onQueue(queue: AudioQueueSnapshot) {
        val previousId = _local.value.current?.id
        updateLocal { state ->
            state.copy(
                connected = true,
                current = queue.currentSong,
                contextSongs = queue.contextSongs,
                contextIndex = queue.currentIndex,
                userQueue = queue.userQueue,
                isInUserQueue = queue.isInUserQueue,
                playedUserQueueHistory = queue.playedUserQueueHistory,
                shuffle = queue.isShuffleActive,
                repeat = RepeatMode.fromValue(queue.repeatMode),
                source = queue.sourceId,
                sourceName = queue.sourceName,
            )
        }
        reconcileSourceSongs(queue)
        if (queue.currentSong?.id != previousId) onCurrentSongChanged(queue.currentSong)
        updateHistoryTracking()
    }

    /**
     * The queue can be replaced from outside this controller (handoff, remote
     * commands, restore). When that happens the remembered source no longer
     * describes it, so fall back to what the engine reports.
     */
    private fun reconcileSourceSongs(queue: AudioQueueSnapshot) {
        if (queue.contextSongs.isEmpty()) {
            sourceSongs = emptyList()
            return
        }
        val known = sourceSongs.mapTo(HashSet()) { it.id }
        if (known.isEmpty() || queue.contextSongs.any { it.id !in known }) {
            sourceSongs = queue.contextSongs
        }
    }

    private fun onCurrentSongChanged(song: QueueSong?) {
        if (song == null) {
            updateLocal { it.copy(isCurrentStarred = false) }
            service?.setLikeActive(false)
            return
        }
        scope.launch {
            val starred = library.localSong(song.id)?.isStarred
                ?: knownSongs.get(song.id)?.isStarred
                ?: false
            if (_local.value.current?.id == song.id) {
                updateLocal { it.copy(isCurrentStarred = starred) }
                service?.setLikeActive(starred)
            }
        }
    }

    private fun onEvent(event: AudioEvent) {
        when (event) {
            is AudioEvent.Error -> {
                Log.w(TAG, "Playback error ${event.code}: ${event.message}")
                val key = if (_local.value.isRadio) "radios.error" else "warnings.songError"
                toaster.error(strings().t(key))
            }
            is AudioEvent.RemoteCommand -> onSystemCommand(event.command)
            is AudioEvent.SleepTimerFired -> _sleepTimer.value = SleepTimerState()
            is AudioEvent.SystemVolumeChanged -> setLocalVolume(event.volume)
            else -> Unit
        }
    }

    /**
     * Commands from the notification, lock screen, or headset that the
     * service cannot complete on its own. While another device is projected
     * the service forwards them there instead.
     */
    private fun onSystemCommand(command: String) {
        if (service?.isRemotePlaybackProjectionActive == true) return
        when (command) {
            "like" -> toggleCurrentLike()
            "shuffle" -> toggleShuffle()
            "togglePlayPause" -> togglePlayPause()
        }
    }

    // endregion

    // region Transport

    fun play() {
        if (sendRemote(RemoteCommand.Play)) {
            setRemotePlaying(true)
            return
        }
        run(AudioCommand.Play)
    }

    fun pause() {
        if (sendRemote(RemoteCommand.Pause)) {
            setRemotePlaying(false)
            return
        }
        pauseLocal()
    }

    /** Pauses this device, also while another one is controlled. */
    fun pauseLocal() = run(AudioCommand.Pause)

    fun togglePlayPause() {
        _remote.value?.let { remote ->
            sendRemote(RemoteCommand.TogglePlayPause)
            setRemotePlaying(!remote.snapshot.snapshot.isPlaying)
            return
        }
        if (!_local.value.hasMedia) return
        run(AudioCommand.TogglePlayPause)
    }

    fun next() {
        if (sendRemote(RemoteCommand.Next)) return
        if (_local.value.isRadio) return
        run(AudioCommand.Next)
    }

    fun previous() {
        if (sendRemote(RemoteCommand.Previous)) return
        if (_local.value.isRadio) return
        run(AudioCommand.Previous)
    }

    fun seek(seconds: Double) {
        val position = seconds.coerceAtLeast(0.0)
        if (sendRemote(RemoteCommand.Seek(position))) {
            updateRemote { it.copy(snapshot = it.snapshot.carriedTo(position = position)) }
            return
        }
        if (_local.value.isRadio) return
        setLocalProgress(_localProgress.value.copy(position = position))
        run(AudioCommand.Seek(seconds))
    }

    fun setVolume(value: Double) {
        val clamped = value.coerceIn(0.0, 1.0)
        if (sendRemote(RemoteCommand.SetVolume(clamped))) {
            _volume.value = clamped
            updateRemote {
                it.copy(snapshot = it.snapshot.copy(snapshot = it.snapshot.snapshot.copy(volume = clamped)))
            }
            return
        }
        setLocalVolume(clamped)
        service?.setSystemVolume(clamped)
    }

    // endregion

    // region Starting playback

    /**
     * Plays [songs] starting at [index] (a random start when shuffling with a
     * null index). Asks before discarding manually queued songs.
     */
    fun playSongs(
        songs: List<Song>,
        index: Int? = 0,
        shuffle: Boolean = false,
        source: QueueSource? = null,
        sourceName: String? = null,
        bypassConfirmation: Boolean = false,
    ) {
        if (songs.isEmpty()) return
        remember(songs)
        val useAlbumCover = settings.current.useAlbumCoverForSongs
        val queueSongs = songs.map { it.toQueueSong(useAlbumCover) }
        val start = when {
            index != null -> index
            shuffle -> QueuePlanner.pickStartIndex(queueSongs, shuffleStartHistory)
            else -> 0
        }.coerceIn(0, queueSongs.lastIndex)

        _remote.value?.let { remote ->
            playRemotely(remote, queueSongs, start, shuffle, source, sourceName, bypassConfirmation)
            return
        }

        val current = _local.value
        val sameContext = !shuffle &&
            !current.isRadio &&
            !current.isInUserQueue &&
            !current.shuffle &&
            current.current?.id == queueSongs[start].id &&
            current.source == source?.toSourceId() &&
            sourceSongs.size == queueSongs.size &&
            sourceSongs.indices.all { sourceSongs[it].id == queueSongs[it].id }
        if (sameContext) {
            play()
            return
        }

        val request = ReplacementRequest(queueSongs, start, shuffle, source, sourceName)
        if (!bypassConfirmation && needsConfirmation()) {
            _pendingReplacement.value = request
            return
        }
        startQueue(request)
    }

    fun playSong(song: Song) {
        _remote.value?.let { remote ->
            remember(listOf(song))
            val snapshot = remote.snapshot.snapshot
            if (snapshot.songId == song.id) {
                play()
                return
            }
            val request = ReplacementRequest(
                songs = listOf(song.toQueueSong(settings.current.useAlbumCoverForSongs)),
                index = 0,
                shuffle = false,
                source = null,
                sourceName = null,
                targetDeviceId = remote.deviceId,
                single = true,
            )
            if (needsConfirmation(snapshot)) {
                _pendingReplacement.value = request
            } else {
                sendRemote(RemoteCommand.PlaySong(song.id))
            }
            return
        }
        val current = _local.value
        if (!current.isRadio && current.current?.id == song.id) {
            play()
            return
        }
        playSongs(listOf(song), 0)
    }

    private fun needsConfirmation(): Boolean {
        val current = _local.value
        return QueuePlanner.shouldConfirmReplacement(
            isPlaying = current.isPlaying,
            userQueueSize = current.userQueue.size,
            isInUserQueue = current.isInUserQueue,
        )
    }

    /** The same question, about what the controlled device plays. */
    private fun needsConfirmation(snapshot: PlaybackSnapshot): Boolean =
        QueuePlanner.shouldConfirmReplacement(
            isPlaying = snapshot.isPlaying,
            userQueueSize = snapshot.userQueue.size,
            isInUserQueue = snapshot.inUserQueue,
        )

    /** Resolves the pending request: replace the queue, or queue it up next. */
    fun confirmReplacement(replaceQueue: Boolean) {
        val request = _pendingReplacement.value ?: return
        _pendingReplacement.value = null
        // Asked about another playback target than the current one.
        if (request.targetDeviceId != _remote.value?.deviceId) return
        if (request.targetDeviceId != null) {
            when {
                !replaceQueue -> sendRemote(
                    RemoteCommand.AddToQueueNext(
                        QueuePlanner.replacementPlayNext(request.songs, request.index, request.shuffle)
                            .map { it.id },
                    ),
                )
                request.single -> sendRemote(RemoteCommand.PlaySong(request.songs[request.index].id))
                else -> startRemoteQueue(request)
            }
            return
        }
        if (replaceQueue) {
            startQueue(request)
        } else {
            enqueue(
                QueuePlanner.replacementPlayNext(request.songs, request.index, request.shuffle),
                "next",
            )
        }
    }

    fun dismissReplacement() {
        _pendingReplacement.value = null
    }

    private fun startQueue(request: ReplacementRequest) {
        val audio = service ?: return
        val repeat = _local.value.repeat
        val shuffle = request.shuffle && request.songs.size > 1
        val queue = QueuePlanner.build(
            songs = request.songs,
            index = request.index,
            repeatAll = repeat == RepeatMode.All,
            shuffle = shuffle,
        )
        sourceSongs = request.songs
        radioList = emptyList()
        if (shuffle) {
            shuffleStartHistory = QueuePlanner.pushStartHistory(
                shuffleStartHistory,
                request.songs[request.index].id,
                request.songs.size,
            )
        }
        scope.launch {
            val result = audio.execute(
                AudioCommand.SetContextQueue(
                    songs = queue,
                    currentIndex = 0,
                    autoplay = true,
                    startTime = null,
                    sourceId = request.source?.toSourceId(),
                    sourceName = request.sourceName,
                    repeatMode = repeat.value,
                ),
            )
            if (result is AudioCommandResult.Failure) {
                report(result)
                return@launch
            }
            if (shuffle) audio.execute(AudioCommand.MarkAsShuffled(request.songs))
        }
    }

    fun playRadio(radios: List<Radio>, index: Int) {
        // Radio stations play here only, as on the web.
        if (_remote.value != null) return
        val radio = radios.getOrNull(index) ?: return
        val current = _local.value
        if (current.isRadio && current.radio?.id == radio.id) {
            play()
            return
        }
        radioList = radios
        sourceSongs = emptyList()
        updateLocal { it.copy(radio = radio, mediaType = MediaType.Radio) }
        run(
            AudioCommand.PlayRadio(
                radioId = radio.id,
                name = radio.name,
                streamUrl = radio.streamUrl,
                subtitle = strings().t("radios.label"),
            ),
        )
    }

    /** Stops playback and empties the queue; does nothing to a controlled device. */
    fun clear() {
        if (_remote.value != null) return
        clearLocal()
    }

    private fun clearLocal() {
        _pendingReplacement.value = null
        radioList = emptyList()
        sourceSongs = emptyList()
        cancelSleepTimer()
        run(AudioCommand.ClearPlayback)
    }

    // endregion

    // region Queue edits

    fun playFromContext(index: Int) {
        _remote.value?.let { remote ->
            sendRemote(RemoteCommand.PlayAtIndex(remote.snapshot.snapshot.contextQueue, index))
            return
        }
        run(AudioCommand.PlayAtIndex(index, null))
    }

    fun playFromUserQueue(index: Int) {
        _remote.value?.let { remote ->
            val snapshot = remote.snapshot.snapshot
            sendRemote(
                RemoteCommand.PlayAtIndex(
                    snapshot.contextQueue + snapshot.userQueue,
                    snapshot.contextQueue.size + index,
                ),
            )
            return
        }
        run(AudioCommand.PlayUserQueueAt(index))
    }

    /**
     * Plays [song] right away and keeps everything that is queued, the way a
     * song picked from the play history starts: it is queued next and then
     * skipped to.
     */
    fun playNow(song: Song) {
        if (_remote.value != null) {
            remember(listOf(song))
            sendRemote(RemoteCommand.AddToQueueNext(listOf(song.id)))
            sendRemote(RemoteCommand.Next)
            return
        }
        val audio = service
        val current = _local.value
        if (audio == null || !current.hasMedia || current.isRadio) {
            playSongs(listOf(song), 0, bypassConfirmation = true)
            return
        }
        remember(listOf(song))
        val queueSong = song.toQueueSong(settings.current.useAlbumCoverForSongs)
        scope.launch {
            val added = audio.execute(AudioCommand.AddToUserQueue(listOf(queueSong), "next"))
            if (added is AudioCommandResult.Failure) {
                report(added)
                return@launch
            }
            // "Next" lands behind a user-queue song that is playing.
            val index = if (audio.queueState.value.isInUserQueue) 1 else 0
            val played = audio.execute(AudioCommand.PlayUserQueueAt(index))
            if (played is AudioCommandResult.Failure) report(played)
        }
    }

    fun addToQueueNext(songs: List<Song>) = addToQueue(songs, "next")

    fun addToQueueLast(songs: List<Song>) = addToQueue(songs, "last")

    private fun addToQueue(songs: List<Song>, position: String) {
        if (songs.isEmpty()) return
        remember(songs)
        val ids = songs.map { it.id }
        val command = if (position == "next") {
            RemoteCommand.AddToQueueNext(ids)
        } else {
            RemoteCommand.AddToQueueLast(ids)
        }
        if (sendRemote(command)) return
        if (!_local.value.hasMedia || _local.value.isRadio) {
            playSongs(songs, 0, bypassConfirmation = true)
            return
        }
        val useAlbumCover = settings.current.useAlbumCoverForSongs
        enqueue(songs.map { it.toQueueSong(useAlbumCover) }, position)
    }

    private fun enqueue(songs: List<QueueSong>, position: String) {
        if (songs.isEmpty()) return
        run(AudioCommand.AddToUserQueue(songs, position))
    }

    // Removing and moving songs of a controlled device's queue is not offered,
    // as on the web: the protocol addresses songs by id, not by position.

    fun removeFromUserQueue(index: Int) {
        if (_remote.value != null) return
        run(AudioCommand.RemoveFromUserQueue(listOf(index)))
    }

    fun removeFromContext(index: Int) {
        if (_remote.value != null) return
        val current = _local.value
        val removed = current.contextSongs.getOrNull(index) ?: return
        val (songs, nextIndex) = QueuePlanner.removeFromContext(
            songs = current.contextSongs,
            currentIndex = current.contextIndex,
            isInUserQueue = current.isInUserQueue,
            removedIndex = index,
        ) ?: return
        sourceSongs = sourceSongs.filterNot { it.id == removed.id }
        run(AudioCommand.UpdateContextQueue(songs, nextIndex))
    }

    fun reorderUserQueue(fromIndex: Int, toIndex: Int) {
        if (_remote.value != null) return
        run(AudioCommand.ReorderUserQueue(fromIndex, toIndex))
    }

    fun reorderContext(fromIndex: Int, toIndex: Int) {
        if (_remote.value != null) return
        run(AudioCommand.ReorderContextQueue(fromIndex, toIndex))
    }

    fun clearUserQueue() {
        if (sendRemote(RemoteCommand.ClearQueue)) return
        run(AudioCommand.ClearUserQueue)
    }

    // endregion

    // region Shuffle and repeat

    fun toggleShuffle() {
        _remote.value?.let { remote ->
            sendRemote(RemoteCommand.SetShuffle(!remote.snapshot.snapshot.shuffle))
            return
        }
        val current = _local.value
        if (current.isRadio || current.contextSongs.isEmpty()) return
        setShuffle(!current.shuffle)
    }

    fun setShuffle(enabled: Boolean) {
        if (sendRemote(RemoteCommand.SetShuffle(enabled))) return
        val audio = service ?: return
        val current = _local.value
        if (current.shuffle == enabled) return
        val rebuilt = rebuildContext(current, current.repeat, enabled)
        scope.launch {
            audio.execute(AudioCommand.SetShuffle(enabled))
            if (rebuilt != null) audio.execute(AudioCommand.UpdateContextQueue(rebuilt, 0))
        }
    }

    fun cycleRepeat() = setRepeat(_state.value.repeat.next())

    fun setRepeat(mode: RepeatMode) {
        if (sendRemote(RemoteCommand.SetRepeat(mode.value))) return
        val audio = service ?: return
        val current = _local.value
        if (current.repeat == mode) return
        // Repeat-all brings back the songs before the current one; turning it
        // off drops them again. Repeat-one keeps the order of repeat-off.
        val membershipChanges = (current.repeat == RepeatMode.All) != (mode == RepeatMode.All)
        val rebuilt = if (membershipChanges) rebuildContext(current, mode, current.shuffle) else null
        scope.launch {
            audio.execute(AudioCommand.SetRepeat(mode.value))
            if (rebuilt != null) audio.execute(AudioCommand.UpdateContextQueue(rebuilt, 0))
        }
    }

    /** Context queue rebuilt from the source list around the current context song. */
    private fun rebuildContext(
        current: PlayerState,
        repeat: RepeatMode,
        shuffle: Boolean,
    ): List<QueueSong>? {
        val anchor = current.contextSongs.getOrNull(current.contextIndex) ?: return null
        val source = sourceSongs.takeIf { songs -> songs.any { it.id == anchor.id } }
            ?: current.contextSongs
        val anchorIndex = source.indexOfFirst { it.id == anchor.id }.coerceAtLeast(0)
        return QueuePlanner.build(source, anchorIndex, repeat == RepeatMode.All, shuffle)
    }

    // endregion

    // region Likes

    fun toggleCurrentLike() {
        _remote.value?.let { remote ->
            val songId = remote.snapshot.snapshot.songId.takeIf(String::isNotEmpty) ?: return
            // The controlled device stars it; shown here until its library says so.
            sendRemote(RemoteCommand.ToggleLike)
            remoteLikes[songId] = !_state.value.isCurrentStarred
            publishRemote()
            return
        }
        val current = _local.value
        val queueSong = current.current ?: return
        setSongStarred(songFor(queueSong), !current.isCurrentStarred)
    }

    /** Stars or unstars [song] on the server and locally, optimistically. */
    fun setSongStarred(song: Song, starred: Boolean, onResult: (Boolean) -> Unit = {}) {
        val isCurrent = _local.value.current?.id == song.id
        if (isCurrent) applyCurrentStarred(starred)
        scope.launch {
            val succeeded = runSuspendCatching { library.setSongStarred(song, starred) }.isSuccess
            if (!succeeded) {
                if (_local.value.current?.id == song.id) applyCurrentStarred(!starred)
                toaster.error(strings().t("toast.server.error"))
            } else {
                knownSongs.get(song.id)?.let { known ->
                    knownSongs.put(
                        song.id,
                        known.copy(
                            starred = if (starred) {
                                formatIsoTimestamp(System.currentTimeMillis())
                            } else {
                                null
                            },
                        ),
                    )
                }
            }
            onResult(succeeded)
        }
    }

    private fun applyCurrentStarred(starred: Boolean) {
        updateLocal { it.copy(isCurrentStarred = starred) }
        service?.setLikeActive(starred)
    }

    // endregion

    // region Sleep timer

    fun startSleepTimer(seconds: Int) {
        _sleepTimer.value = SleepTimerState(
            active = true,
            endsAtMillis = System.currentTimeMillis() + seconds * 1000L,
        )
        run(AudioCommand.SetSleepTimer(seconds.toDouble(), "duration"))
    }

    fun startEndOfTrackTimer() {
        _sleepTimer.value = SleepTimerState(active = true, endOfTrack = true)
        run(AudioCommand.SetSleepTimer(0.0, "endOfTrack"))
    }

    fun cancelSleepTimer() {
        if (!_sleepTimer.value.active) return
        _sleepTimer.value = SleepTimerState()
        run(AudioCommand.CancelSleepTimer)
    }

    // endregion

    // region Song metadata and history

    /** Full metadata for a queue entry when it is known, otherwise a minimal song. */
    fun songFor(queueSong: QueueSong): Song = knownSongs.get(queueSong.id) ?: queueSong.toSong()

    fun remember(songs: List<Song>) {
        for (song in songs) knownSongs.put(song.id, song)
    }

    /** Songs played for at least ten seconds, newest first. */
    suspend fun playHistory(): List<Song> {
        val limit = settings.current.playHistoryMaxSize
        return preferences.getPlayHistory(limit).mapNotNull { raw ->
            runCatching { SubsonicApi.json.decodeFromString(Song.serializer(), raw) }.getOrNull()
        }
    }

    suspend fun clearPlayHistory() {
        preferences.clearPlayHistory()
        _historyVersion.update { it + 1 }
    }

    /** Drops the oldest entries once the history limit is lowered. */
    private suspend fun trimPlayHistory(maxSize: Int) {
        val stored = runCatching { preferences.getPlayHistory(Int.MAX_VALUE) }.getOrNull() ?: return
        if (stored.size <= maxSize) return
        runCatching { preferences.setPlayHistory(stored.take(maxSize)) }
        _historyVersion.update { it + 1 }
    }

    private fun updateHistoryTracking() {
        val current = _local.value
        val song = current.current?.takeIf { !current.isRadio }
        val now = SystemClock.elapsedRealtime()
        val active = tracked

        if (active != null && active.song.id != song?.id) {
            finishTracking(active, now)
            tracked = null
        }
        if (song == null) return

        val entry = tracked
        if (entry == null) {
            if (current.isPlaying) tracked = TrackedPlay(song, playingSince = now)
            return
        }
        if (current.isPlaying && entry.playingSince == null) {
            entry.playingSince = now
        } else if (!current.isPlaying && entry.playingSince != null) {
            entry.accumulatedMs += now - (entry.playingSince ?: now)
            entry.playingSince = null
        }
        // Long listens are recorded while they are still playing.
        if (!entry.recorded && entry.playedMs(now) >= MIN_HISTORY_PLAY_MS) {
            entry.recorded = true
            recordHistory(entry.song)
        }
    }

    private fun finishTracking(entry: TrackedPlay, now: Long) {
        if (!entry.recorded && entry.playedMs(now) >= MIN_HISTORY_PLAY_MS) {
            entry.recorded = true
            recordHistory(entry.song)
        }
    }

    private fun recordHistory(queueSong: QueueSong) {
        val song = songFor(queueSong)
        val maxSize = settings.current.playHistoryMaxSize
        scope.launch {
            runCatching {
                preferences.addToPlayHistory(
                    SubsonicApi.json.encodeToString(Song.serializer(), song),
                    maxSize,
                )
            }
            _historyVersion.update { it + 1 }
        }
    }

    // endregion

    // region Remote control

    /**
     * Shows [playback] instead of this device's own and sends what the user
     * does to it through [send]. Called again with every new snapshot.
     */
    fun showRemote(playback: RemotePlayback, send: (RemoteCommand) -> Unit) {
        if (_remote.value?.deviceId != playback.deviceId) {
            // A question asked about another playback target no longer applies.
            _pendingReplacement.value = null
            remoteLikes.clear()
            unknownRemoteSongs.clear()
        }
        remoteSend = send
        _remote.value = playback
        lookUpRemoteSongs()
        publishRemote()
    }

    /** Back to the playback of this device. */
    fun hideRemote() {
        if (_remote.value == null) return
        _remote.value = null
        remoteSend = null
        remoteTicker?.cancel()
        remoteLookup?.cancel()
        remoteLikes.clear()
        _pendingReplacement.value = null
        _state.value = _local.value
        _progress.value = _localProgress.value
        _volume.value = _localVolume.value
    }

    /** Sends [command] to the controlled device; false when there is none. */
    private fun sendRemote(command: RemoteCommand): Boolean {
        val send = remoteSend ?: return false
        if (_remote.value == null) return false
        send(command)
        return true
    }

    /** What the web player sends to start a list on another device (`sendSongListRemote`). */
    private fun playRemotely(
        remote: RemotePlayback,
        songs: List<QueueSong>,
        start: Int,
        shuffle: Boolean,
        source: QueueSource?,
        sourceName: String?,
        bypassConfirmation: Boolean,
    ) {
        val snapshot = remote.snapshot.snapshot
        val remoteContext = snapshot.contextQueue.drop(snapshot.contextIndex ?: 0)
        val requested = songs.drop(start).map { it.id }
        val sameContext = !snapshot.inUserQueue &&
            !snapshot.shuffle &&
            snapshot.songId == songs[start].id &&
            snapshot.sourceId == source?.let { "${it.type}:${it.id}" } &&
            remoteContext == requested
        if (!shuffle && sameContext) {
            play()
            return
        }
        val request = ReplacementRequest(
            songs = songs,
            index = start,
            shuffle = shuffle,
            source = source,
            sourceName = sourceName,
            targetDeviceId = remote.deviceId,
        )
        if (!bypassConfirmation && needsConfirmation(snapshot)) {
            _pendingReplacement.value = request
            return
        }
        startRemoteQueue(request)
    }

    private fun startRemoteQueue(request: ReplacementRequest) {
        val source = request.source
        when (source?.type) {
            "album" -> sendRemote(RemoteCommand.PlayAlbum(source.id, request.index, request.shuffle))
            "playlist" -> sendRemote(RemoteCommand.PlayPlaylist(source.id, request.index, request.shuffle))
            else -> {
                val ids = request.songs.map { it.id }
                sendRemote(RemoteCommand.ClearQueue)
                sendRemote(RemoteCommand.AddToQueueLast(ids))
                sendRemote(RemoteCommand.PlaySong(ids[request.index]))
                if (request.shuffle) sendRemote(RemoteCommand.SetShuffle(true))
            }
        }
        setRemotePlaying(true)
    }

    /** Shows the controlled device as playing or paused until it reports back. */
    private fun setRemotePlaying(playing: Boolean) {
        updateRemote { it.copy(snapshot = it.snapshot.carriedTo(isPlaying = playing)) }
    }

    private fun updateRemote(transform: (RemotePlayback) -> RemotePlayback) {
        val current = _remote.value ?: return
        _remote.value = transform(current)
        publishRemote()
    }

    /** The remote device's playback in the shape the screens read. */
    private fun publishRemote() {
        val remote = _remote.value ?: return
        val snapshot = remote.snapshot.snapshot
        val useAlbumCover = settings.current.useAlbumCoverForSongs
        val songs = HashMap<String, QueueSong>()
        fun song(id: String): QueueSong = songs.getOrPut(id) {
            remoteSongs[id]?.toQueueSong(useAlbumCover) ?: unknownSong(
                id = id,
                duration = if (id == snapshot.songId) snapshot.durationSeconds else 0.0,
                looking = id !in unknownRemoteSongs,
            )
        }
        val songId = snapshot.songId.takeIf(String::isNotEmpty)
        _state.value = PlayerState(
            connected = true,
            current = songId?.let(::song),
            isPlaying = snapshot.isPlaying,
            shuffle = snapshot.shuffle,
            repeat = RepeatMode.fromValue(snapshot.repeat),
            contextSongs = snapshot.contextQueue.map(::song),
            contextIndex = (snapshot.contextIndex ?: 0).coerceAtLeast(0),
            userQueue = snapshot.userQueue.map(::song),
            isInUserQueue = snapshot.inUserQueue,
            playedUserQueueHistory = snapshot.restorePrevious.map(::song),
            source = snapshot.sourceId?.let(::decodeSource),
            sourceName = snapshot.sourceName,
            isCurrentStarred = songId?.let { remoteLikes[it] ?: remoteSongs[it]?.isStarred } ?: false,
            remoteDevice = remote.deviceName,
        )
        snapshot.volume?.let { _volume.value = it.coerceIn(0.0, 1.0) }
        publishRemoteProgress()
        if (snapshot.isPlaying) {
            if (remoteTicker?.isActive != true) {
                remoteTicker = scope.launch {
                    while (true) {
                        delay(REMOTE_PROGRESS_INTERVAL_MS)
                        publishRemoteProgress()
                    }
                }
            }
        } else {
            remoteTicker?.cancel()
        }
    }

    private fun publishRemoteProgress() {
        val remote = _remote.value ?: return
        _progress.value = PlaybackProgress(
            position = remote.snapshot.progressAt(SystemClock.elapsedRealtime()),
            duration = remote.snapshot.snapshot.durationSeconds.coerceAtLeast(0.0),
        )
    }

    /** Finds the songs the controlled device names, in the library or on the server. */
    private fun lookUpRemoteSongs() {
        if (remoteLookup?.isActive == true) return
        val snapshot = _remote.value?.snapshot?.snapshot ?: return
        val wanted = (
            listOf(snapshot.songId) + snapshot.contextQueue + snapshot.userQueue +
                snapshot.restorePrevious
            )
            .filter { it.isNotEmpty() && it !in remoteSongs && it !in unknownRemoteSongs }
            .distinct()
        if (wanted.isEmpty()) return
        remoteLookup = scope.launch {
            val found = runSuspendCatching { library.songsByIds(wanted) }.getOrNull() ?: return@launch
            remoteSongs.putAll(found)
            remember(found.values.toList())
            unknownRemoteSongs.addAll(wanted.filterNot { it in found })
            publishRemote()
            // A snapshot that arrived meanwhile may name other songs.
            remoteLookup = null
            lookUpRemoteSongs()
        }
    }

    private fun unknownSong(id: String, duration: Double, looking: Boolean) = QueueSong(
        id = id,
        title = strings().t(
            if (looking) {
                "settings.crossDevice.playback.fetchingSong"
            } else {
                "settings.crossDevice.playback.unknownTrack"
            },
        ),
        artist = "",
        artistId = null,
        album = "",
        albumId = null,
        duration = duration,
        coverArtId = null,
        streamUrl = "",
        cachedFileUri = null,
    )

    /** A source in the "type:id" form of the protocol. */
    private fun decodeSource(raw: String): QueueSourceId? {
        val separator = raw.indexOf(':')
        if (separator <= 0 || separator == raw.lastIndex) return null
        return QueueSourceId(raw.substring(0, separator), raw.substring(separator + 1))
    }

    // endregion

    private fun updateLocal(transform: (PlayerState) -> PlayerState) {
        _local.update(transform)
        if (_remote.value == null) _state.value = _local.value
    }

    private fun setLocalProgress(progress: PlaybackProgress) {
        _localProgress.value = progress
        if (_remote.value == null) _progress.value = progress
    }

    private fun setLocalVolume(volume: Double) {
        _localVolume.value = volume
        if (_remote.value == null) _volume.value = volume
    }

    private fun run(command: AudioCommand) {
        val audio = service ?: return
        scope.launch {
            val result = audio.execute(command)
            if (result is AudioCommandResult.Failure) report(result)
        }
    }

    private fun report(failure: AudioCommandResult.Failure) {
        Log.w(TAG, "Audio command failed ${failure.code}: ${failure.message}")
    }

    private fun ReplayGainSettings.toConfig() = ReplayGainConfig(
        enabled = enabled,
        mode = if (type == ReplayGainType.Album) "album" else "track",
        preAmp = preAmp.toDouble(),
        defaultGain = defaultGain.toDouble(),
    )

    private class TrackedPlay(
        val song: QueueSong,
        var accumulatedMs: Long = 0,
        var playingSince: Long? = null,
        var recorded: Boolean = false,
    ) {
        fun playedMs(now: Long): Long = accumulatedMs + (playingSince?.let { now - it } ?: 0)
    }

    private companion object {
        const val TAG = "PlayerController"
        const val MIN_HISTORY_PLAY_MS = 10_000L
        const val KNOWN_SONGS_CAPACITY = 2_000
        const val REMOTE_PROGRESS_INTERVAL_MS = 250L
    }
}
