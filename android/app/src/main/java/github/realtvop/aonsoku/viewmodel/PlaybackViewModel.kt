package github.realtvop.aonsoku.viewmodel

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.audio.AudioCommand
import github.realtvop.aonsoku.plugins.audio.AudioPlaybackSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioQueueSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioService
import github.realtvop.aonsoku.plugins.audio.PlaybackService
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.plugins.data.db.entity.LyricsEntity
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

class PlaybackViewModel(application: Application) : AndroidViewModel(application) {
    private val appServices = AppServices.getInstance(application)
    private val libraryService = appServices.library

    private var audioService: AudioService? = null
    private var isBound = false
    private var playbackStateJob: Job? = null
    private var queueStateJob: Job? = null

    private val _playbackState = MutableStateFlow(AudioPlaybackSnapshot())
    val playbackState: StateFlow<AudioPlaybackSnapshot> = _playbackState.asStateFlow()

    private val _queueState = MutableStateFlow(AudioQueueSnapshot())
    val queueState: StateFlow<AudioQueueSnapshot> = _queueState.asStateFlow()

    private val _currentSong = MutableStateFlow<QueueSong?>(null)
    val currentSong: StateFlow<QueueSong?> = _currentSong.asStateFlow()

    private val _lyrics = MutableStateFlow<LyricsEntity?>(null)
    val lyrics: StateFlow<LyricsEntity?> = _lyrics.asStateFlow()

    private val _isCurrentSongFavorite = MutableStateFlow(false)
    val isCurrentSongFavorite: StateFlow<Boolean> = _isCurrentSongFavorite.asStateFlow()

    // Fullscreen and overlay UI state
    private val _isFullscreenOpen = MutableStateFlow(false)
    val isFullscreenOpen: StateFlow<Boolean> = _isFullscreenOpen.asStateFlow()

    private val _isQueueSheetOpen = MutableStateFlow(false)
    val isQueueSheetOpen: StateFlow<Boolean> = _isQueueSheetOpen.asStateFlow()

    private val _isLyricsOpen = MutableStateFlow(false)
    val isLyricsOpen: StateFlow<Boolean> = _isLyricsOpen.asStateFlow()

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? PlaybackService.LocalBinder
            val boundAudio = binder?.getAudioService() ?: appServices.audioService()
            audioService = boundAudio
            isBound = true

            boundAudio?.let { svc ->
                playbackStateJob?.cancel()
                playbackStateJob = viewModelScope.launch {
                    svc.playbackState.collectLatest { snapshot ->
                        _playbackState.value = snapshot
                    }
                }

                queueStateJob?.cancel()
                queueStateJob = viewModelScope.launch {
                    svc.queueState.collectLatest { snapshot ->
                        _queueState.value = snapshot
                        val song = snapshot.currentSong
                        if (song?.id != _currentSong.value?.id) {
                            _currentSong.value = song
                            if (song != null) {
                                loadSongDetails(song.id)
                            } else {
                                _lyrics.value = null
                                _isCurrentSongFavorite.value = false
                            }
                        }
                    }
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            audioService = null
            isBound = false
            playbackStateJob?.cancel()
            queueStateJob?.cancel()
        }
    }

    init {
        bindService()
    }

    private fun bindService() {
        val context = getApplication<Application>()
        val intent = Intent(context, PlaybackService::class.java)
        try {
            context.startService(intent)
        } catch (_: Exception) {}
        context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
    }

    private fun loadSongDetails(songId: String) {
        viewModelScope.launch {
            val songEntity = libraryService.getSong(songId)
            _isCurrentSongFavorite.value = songEntity?.let {
                it.starred != null || (it.starredAt ?: 0L) > 0L
            } ?: false

            _lyrics.value = libraryService.getLyrics(songId)
        }
    }

    fun openFullscreen() {
        _isFullscreenOpen.value = true
    }

    fun closeFullscreen() {
        _isFullscreenOpen.value = false
    }

    fun setQueueSheetOpen(open: Boolean) {
        _isQueueSheetOpen.value = open
    }

    fun toggleLyrics() {
        _isLyricsOpen.value = !_isLyricsOpen.value
    }

    fun executeCommand(command: AudioCommand) {
        viewModelScope.launch {
            audioService?.execute(command)
        }
    }

    fun togglePlayPause() = executeCommand(AudioCommand.TogglePlayPause)

    fun play() = executeCommand(AudioCommand.Play)

    fun pause() = executeCommand(AudioCommand.Pause)

    fun next() = executeCommand(AudioCommand.Next)

    fun previous() = executeCommand(AudioCommand.Previous)

    fun seek(seconds: Double) = executeCommand(AudioCommand.Seek(seconds))

    fun toggleShuffle() {
        val currentShuffle = _queueState.value.isShuffleActive
        executeCommand(AudioCommand.SetShuffle(!currentShuffle))
    }

    fun cycleRepeat() {
        val nextMode = when (_queueState.value.repeatMode) {
            "off" -> "all"
            "all" -> "one"
            else -> "off"
        }
        executeCommand(AudioCommand.SetRepeat(nextMode))
    }

    fun playSong(songId: String) = executeCommand(AudioCommand.PlaySongById(songId))

    fun playAlbum(albumId: String, index: Int = 0, shuffle: Boolean = false) =
        executeCommand(AudioCommand.PlayAlbumById(albumId, index, shuffle))

    fun playPlaylist(playlistId: String, index: Int = 0, shuffle: Boolean = false) =
        executeCommand(AudioCommand.PlayPlaylistById(playlistId, index, shuffle))

    fun playSongs(songIds: List<String>, index: Int = 0) =
        executeCommand(AudioCommand.PlaySongsById(songIds, index))

    fun addToQueueNext(songIds: List<String>) =
        executeCommand(AudioCommand.AddSongsById(songIds, "next"))

    fun addToQueueLast(songIds: List<String>) =
        executeCommand(AudioCommand.AddSongsById(songIds, "last"))

    fun playQueueIndex(index: Int) =
        executeCommand(AudioCommand.PlayAtIndex(index, null))

    fun clearQueue() = executeCommand(AudioCommand.ClearUserQueue)

    fun toggleFavorite(songId: String) {
        viewModelScope.launch {
            val starred = libraryService.toggleSongStarred(songId)
            if (_currentSong.value?.id == songId) {
                _isCurrentSongFavorite.value = starred
            }
        }
    }

    fun setSleepTimer(minutes: Int) =
        executeCommand(AudioCommand.SetSleepTimer(minutes * 60.0, "duration"))

    fun cancelSleepTimer() = executeCommand(AudioCommand.CancelSleepTimer)

    override fun onCleared() {
        super.onCleared()
        if (isBound) {
            try {
                getApplication<Application>().unbindService(connection)
            } catch (_: Exception) {}
            isBound = false
        }
    }
}
