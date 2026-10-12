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
import github.realtvop.aonsoku.data.formatIsoTimestamp
import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.data.model.Song
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
import github.realtvop.aonsoku.plugins.audio.ReplayGainConfig
import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import github.realtvop.aonsoku.settings.ReplayGainSettings
import github.realtvop.aonsoku.settings.ReplayGainType
import github.realtvop.aonsoku.settings.SettingsRepository
import github.realtvop.aonsoku.ui.components.Toaster
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
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
    private val _state = MutableStateFlow(PlayerState())
    private val _progress = MutableStateFlow(PlaybackProgress())
    private val _volume = MutableStateFlow(1.0)
    private val _sleepTimer = MutableStateFlow(SleepTimerState())
    private val _pendingReplacement = MutableStateFlow<ReplacementRequest?>(null)
    private val _historyVersion = MutableStateFlow(0)

    val state: StateFlow<PlayerState> = _state.asStateFlow()
    val progress: StateFlow<PlaybackProgress> = _progress.asStateFlow()
    val volume: StateFlow<Double> = _volume.asStateFlow()
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
        clear()
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
        _state.value = PlayerState()
        _progress.value = PlaybackProgress()
        _sleepTimer.value = SleepTimerState()
        _pendingReplacement.value = null
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
        val current = _state.value
        val duration = snapshot.durationSeconds.takeIf { it > 0 }
            ?: current.current?.duration?.takeIf { radioId == null }
            ?: 0.0
        _progress.value = PlaybackProgress(
            position = snapshot.currentTimeSeconds.coerceAtLeast(0.0),
            duration = duration,
            buffered = snapshot.bufferedTimeSeconds,
        )
        _volume.value = snapshot.volume
        _state.update { state ->
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
        val previousId = _state.value.current?.id
        _state.update { state ->
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
            _state.update { it.copy(isCurrentStarred = false) }
            service?.setLikeActive(false)
            return
        }
        scope.launch {
            val starred = library.localSong(song.id)?.isStarred
                ?: knownSongs.get(song.id)?.isStarred
                ?: false
            if (_state.value.current?.id == song.id) {
                _state.update { it.copy(isCurrentStarred = starred) }
                service?.setLikeActive(starred)
            }
        }
    }

    private fun onEvent(event: AudioEvent) {
        when (event) {
            is AudioEvent.Error -> {
                Log.w(TAG, "Playback error ${event.code}: ${event.message}")
                val key = if (_state.value.isRadio) "radios.error" else "warnings.songError"
                toaster.error(strings().t(key))
            }
            is AudioEvent.RemoteCommand -> onSystemCommand(event.command)
            is AudioEvent.SleepTimerFired -> _sleepTimer.value = SleepTimerState()
            is AudioEvent.SystemVolumeChanged -> _volume.value = event.volume
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

    fun play() = run(AudioCommand.Play)

    fun pause() = run(AudioCommand.Pause)

    fun togglePlayPause() {
        if (!_state.value.hasMedia) return
        run(AudioCommand.TogglePlayPause)
    }

    fun next() {
        if (_state.value.isRadio) return
        run(AudioCommand.Next)
    }

    fun previous() {
        if (_state.value.isRadio) return
        run(AudioCommand.Previous)
    }

    fun seek(seconds: Double) {
        if (_state.value.isRadio) return
        _progress.update { it.copy(position = seconds.coerceAtLeast(0.0)) }
        run(AudioCommand.Seek(seconds))
    }

    fun setVolume(value: Double) {
        val clamped = value.coerceIn(0.0, 1.0)
        _volume.value = clamped
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

        val current = _state.value
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
        val current = _state.value
        if (!current.isRadio && current.current?.id == song.id) {
            play()
            return
        }
        playSongs(listOf(song), 0)
    }

    private fun needsConfirmation(): Boolean {
        val current = _state.value
        return QueuePlanner.shouldConfirmReplacement(
            isPlaying = current.isPlaying,
            userQueueSize = current.userQueue.size,
            isInUserQueue = current.isInUserQueue,
        )
    }

    /** Resolves the pending request: replace the queue, or queue it up next. */
    fun confirmReplacement(replaceQueue: Boolean) {
        val request = _pendingReplacement.value ?: return
        _pendingReplacement.value = null
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
        val repeat = _state.value.repeat
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
        val radio = radios.getOrNull(index) ?: return
        val current = _state.value
        if (current.isRadio && current.radio?.id == radio.id) {
            play()
            return
        }
        radioList = radios
        sourceSongs = emptyList()
        _state.update { it.copy(radio = radio, mediaType = MediaType.Radio) }
        run(
            AudioCommand.PlayRadio(
                radioId = radio.id,
                name = radio.name,
                streamUrl = radio.streamUrl,
                subtitle = strings().t("radios.label"),
            ),
        )
    }

    /** Stops playback and empties the queue. */
    fun clear() {
        _pendingReplacement.value = null
        radioList = emptyList()
        sourceSongs = emptyList()
        cancelSleepTimer()
        run(AudioCommand.ClearPlayback)
    }

    // endregion

    // region Queue edits

    fun playFromContext(index: Int) = run(AudioCommand.PlayAtIndex(index, null))

    fun playFromUserQueue(index: Int) = run(AudioCommand.PlayUserQueueAt(index))

    fun addToQueueNext(songs: List<Song>) = addToQueue(songs, "next")

    fun addToQueueLast(songs: List<Song>) = addToQueue(songs, "last")

    private fun addToQueue(songs: List<Song>, position: String) {
        if (songs.isEmpty()) return
        remember(songs)
        if (!_state.value.hasMedia || _state.value.isRadio) {
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

    fun removeFromUserQueue(index: Int) = run(AudioCommand.RemoveFromUserQueue(listOf(index)))

    fun removeFromContext(index: Int) {
        val current = _state.value
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

    fun reorderUserQueue(fromIndex: Int, toIndex: Int) =
        run(AudioCommand.ReorderUserQueue(fromIndex, toIndex))

    fun reorderContext(fromIndex: Int, toIndex: Int) =
        run(AudioCommand.ReorderContextQueue(fromIndex, toIndex))

    fun clearUserQueue() = run(AudioCommand.ClearUserQueue)

    // endregion

    // region Shuffle and repeat

    fun toggleShuffle() {
        val current = _state.value
        if (current.isRadio || current.contextSongs.isEmpty()) return
        setShuffle(!current.shuffle)
    }

    fun setShuffle(enabled: Boolean) {
        val audio = service ?: return
        val current = _state.value
        if (current.shuffle == enabled) return
        val rebuilt = rebuildContext(current, current.repeat, enabled)
        scope.launch {
            audio.execute(AudioCommand.SetShuffle(enabled))
            if (rebuilt != null) audio.execute(AudioCommand.UpdateContextQueue(rebuilt, 0))
        }
    }

    fun cycleRepeat() = setRepeat(_state.value.repeat.next())

    fun setRepeat(mode: RepeatMode) {
        val audio = service ?: return
        val current = _state.value
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
        val current = _state.value
        val queueSong = current.current ?: return
        setSongStarred(songFor(queueSong), !current.isCurrentStarred)
    }

    /** Stars or unstars [song] on the server and locally, optimistically. */
    fun setSongStarred(song: Song, starred: Boolean, onResult: (Boolean) -> Unit = {}) {
        val isCurrent = _state.value.current?.id == song.id
        if (isCurrent) applyCurrentStarred(starred)
        scope.launch {
            val succeeded = runCatching { library.setSongStarred(song, starred) }.isSuccess
            if (!succeeded) {
                if (_state.value.current?.id == song.id) applyCurrentStarred(!starred)
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
        _state.update { it.copy(isCurrentStarred = starred) }
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
        val current = _state.value
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
    }
}
