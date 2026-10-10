package github.realtvop.aonsoku.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.audio.AudioPlaybackSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioQueueSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioService
import github.realtvop.aonsoku.plugins.audio.AudioCommand
import github.realtvop.aonsoku.plugins.audio.AudioEvent
import github.realtvop.aonsoku.plugins.bridge.AuthenticationResult
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.data.AlbumFilter
import github.realtvop.aonsoku.plugins.data.ArtistFilter
import github.realtvop.aonsoku.plugins.data.LibraryPagination
import github.realtvop.aonsoku.plugins.data.LibrarySyncOptions
import github.realtvop.aonsoku.plugins.data.LibrarySyncState
import github.realtvop.aonsoku.plugins.data.SongFilter
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class NativeAppState(
    val isLoading: Boolean = true,
    val isLoggingIn: Boolean = false,
    val credentials: ServerCredentials? = null,
    val loginError: String? = null,
    val actionError: String? = null,
    val needsInitialSync: Boolean = false,
    val sync: LibrarySyncState = LibrarySyncState(
        phase = "idle",
        tier = null,
        isSyncing = false,
        progress = 0,
        processedItems = 0,
        totalItems = 0,
    ),
    val homeAlbums: List<AlbumEntity> = emptyList(),
    val albums: List<AlbumEntity> = emptyList(),
    val artists: List<ArtistEntity> = emptyList(),
    val songs: List<SongEntity> = emptyList(),
    val favoriteSongs: List<SongEntity> = emptyList(),
    val playlists: List<PlaylistEntity> = emptyList(),
    val searchArtists: List<ArtistEntity> = emptyList(),
    val searchAlbums: List<AlbumEntity> = emptyList(),
    val searchSongs: List<SongEntity> = emptyList(),
    val selectedAlbum: AlbumEntity? = null,
    val selectedAlbumSongs: List<SongEntity> = emptyList(),
    val selectedArtist: ArtistEntity? = null,
    val selectedArtistAlbums: List<AlbumEntity> = emptyList(),
    val playback: AudioPlaybackSnapshot = AudioPlaybackSnapshot(),
    val queue: AudioQueueSnapshot = AudioQueueSnapshot(),
)

class AonsokuViewModel(application: Application) : AndroidViewModel(application) {
    private val services = AppServices.getInstance(application)
    private val library = services.library
    private val _state = MutableStateFlow(NativeAppState())
    private var audioService: AudioService? = null
    private var playbackJob: Job? = null
    private var queueJob: Job? = null
    private var eventJob: Job? = null

    val state: StateFlow<NativeAppState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            val initialization = library.initialize()
            val credentials = library.storedCredentials()
            _state.update {
                it.copy(
                    isLoading = false,
                    credentials = credentials,
                    needsInitialSync = initialization.needsMigration,
                )
            }
            if (credentials != null) {
                refreshHome()
            }
        }
        viewModelScope.launch {
            var wasSyncing = false
            library.syncState.collect { sync ->
                val completed = wasSyncing && !sync.isSyncing
                wasSyncing = sync.isSyncing
                _state.update { it.copy(sync = sync) }
                if (completed && _state.value.credentials != null) refreshHome()
            }
        }
    }

    fun attachAudioService(service: AudioService) {
        if (audioService === service) return
        playbackJob?.cancel()
        queueJob?.cancel()
        eventJob?.cancel()
        audioService = service
        playbackJob = viewModelScope.launch {
            service.playbackState.collect { playback ->
                _state.update { it.copy(playback = playback) }
            }
        }
        queueJob = viewModelScope.launch {
            service.queueState.collect { queue ->
                _state.update { it.copy(queue = queue) }
            }
        }
        eventJob = viewModelScope.launch {
            service.events.collect { event ->
                if (event is AudioEvent.Error) {
                    _state.update { it.copy(actionError = event.message) }
                }
            }
        }
    }

    fun detachAudioService() {
        playbackJob?.cancel()
        queueJob?.cancel()
        eventJob?.cancel()
        playbackJob = null
        queueJob = null
        eventJob = null
        audioService = null
    }

    fun login(url: String, fallbackUrl: String, username: String, password: String) {
        if (url.isBlank() || username.isBlank() || password.isBlank()) {
            _state.update { it.copy(loginError = "Server, username, and password are required") }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(isLoggingIn = true, loginError = null) }
            val result = services.authentication.login(
                primaryUrl = url.trim(),
                fallbackUrl = fallbackUrl.trim().ifBlank { null },
                username = username.trim(),
                rawPassword = password,
            )
            if (!result.success) {
                _state.update {
                    it.copy(
                        isLoggingIn = false,
                        loginError = loginErrorMessage(result),
                    )
                }
                return@launch
            }

            library.refreshCredentials()
            val initialization = library.initialize()
            _state.update {
                it.copy(
                    isLoading = false,
                    isLoggingIn = false,
                    credentials = library.storedCredentials(),
                    needsInitialSync = initialization.needsMigration,
                )
            }
            library.syncAll(LibrarySyncOptions("full"))
            refreshHome()
        }
    }

    fun logout() {
        services.authentication.clearCredentials()
        library.cancelSync()
        _state.value = NativeAppState(isLoading = false)
    }

    fun refreshLibrary() {
        viewModelScope.launch {
            library.refreshCredentials()
            library.syncIncremental()
            refreshHome()
        }
    }

    fun refreshHome() {
        viewModelScope.launch {
            val albums = library.getAlbums(
                LibraryPagination(12, 0),
                AlbumFilter(sortBy = "created"),
            )
            _state.update { it.copy(homeAlbums = albums.items) }
        }
    }

    fun loadAlbums() {
        viewModelScope.launch {
            val result = library.getAlbums(
                LibraryPagination(100, 0),
                AlbumFilter(sortBy = "name"),
            )
            _state.update { it.copy(albums = result.items) }
        }
    }

    fun loadArtists() {
        viewModelScope.launch {
            val result = library.getArtists(
                LibraryPagination(100, 0),
                ArtistFilter(sortBy = "name"),
            )
            _state.update { it.copy(artists = result.items) }
        }
    }

    fun loadSongs() {
        viewModelScope.launch {
            val result = library.getSongs(
                LibraryPagination(200, 0),
                SongFilter(sortBy = "title"),
            )
            _state.update { it.copy(songs = result.items) }
        }
    }

    fun loadFavorites() {
        viewModelScope.launch {
            val result = library.getFavorites(LibraryPagination(200, 0), "songs")
            val songs = result.items.mapNotNull { it as? SongEntity }
            _state.update { it.copy(favoriteSongs = songs) }
        }
    }

    fun loadPlaylists() {
        viewModelScope.launch {
            val result = library.getPlaylists(LibraryPagination(100, 0))
            _state.update { it.copy(playlists = result.items) }
        }
    }

    fun loadAlbum(id: String) {
        viewModelScope.launch {
            val result = library.getAlbum(id)
            _state.update {
                it.copy(
                    selectedAlbum = result?.first,
                    selectedAlbumSongs = result?.second.orEmpty(),
                )
            }
        }
    }

    fun loadArtist(id: String) {
        viewModelScope.launch {
            val artist = library.getArtist(id)
            val albums = library.getAlbums(
                LibraryPagination(100, 0),
                AlbumFilter(artistId = id, sortBy = "name"),
            )
            _state.update {
                it.copy(selectedArtist = artist, selectedArtistAlbums = albums.items)
            }
        }
    }

    fun search(query: String) {
        viewModelScope.launch {
            if (query.isBlank()) {
                _state.update {
                    it.copy(searchArtists = emptyList(), searchAlbums = emptyList(), searchSongs = emptyList())
                }
                return@launch
            }
            val result = library.search(query, 10, 10, 20)
            _state.update {
                it.copy(
                    searchArtists = result.artists,
                    searchAlbums = result.albums,
                    searchSongs = result.songs,
                )
            }
        }
    }

    fun playSong(songId: String) {
        executeAudio(AudioCommand.PlaySongById(songId))
    }

    fun playAlbum(albumId: String) {
        executeAudio(AudioCommand.PlayAlbumById(albumId, 0, false))
    }

    fun playPlaylist(playlistId: String) {
        executeAudio(AudioCommand.PlayPlaylistById(playlistId, 0, false))
    }

    fun togglePlayback() {
        executeAudio(AudioCommand.TogglePlayPause)
    }

    fun next() {
        executeAudio(AudioCommand.Next)
    }

    fun previous() {
        executeAudio(AudioCommand.Previous)
    }

    fun seek(positionSeconds: Double) {
        executeAudio(AudioCommand.Seek(positionSeconds.coerceAtLeast(0.0)))
    }

    fun playAtIndex(index: Int) {
        executeAudio(AudioCommand.PlayAtIndex(index, null))
    }

    fun addSongToQueue(songId: String, position: String = "last") {
        executeAudio(AudioCommand.AddSongsById(listOf(songId), position))
    }

    fun removeFromQueue(songId: String) {
        executeAudio(AudioCommand.RemoveSongsById(listOf(songId)))
    }

    fun clearUserQueue() {
        executeAudio(AudioCommand.ClearUserQueue)
    }

    fun toggleShuffle() {
        executeAudio(AudioCommand.SetShuffle(!state.value.queue.isShuffleActive))
    }

    fun cycleRepeat() {
        val nextMode = when (state.value.queue.repeatMode) {
            "off" -> "all"
            "all" -> "one"
            else -> "off"
        }
        executeAudio(AudioCommand.SetRepeat(nextMode))
    }

    fun toggleFavorite(songId: String) {
        viewModelScope.launch {
            library.toggleSongStarred(songId)
            loadSongs()
            loadFavorites()
        }
    }

    fun clearActionError() {
        _state.update { it.copy(actionError = null) }
    }

    suspend fun coverFile(coverArtId: String): String? {
        return try {
            library.resolveCoverImage(coverArtId)?.file?.absolutePath
                ?: library.downloadCoverImage(coverArtId, "300").file.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun executeAudio(command: AudioCommand) {
        viewModelScope.launch {
            val service = audioService
            if (service == null) {
                _state.update { it.copy(actionError = "Playback service is not ready") }
                return@launch
            }
            when (val result = service.execute(command)) {
                is github.realtvop.aonsoku.plugins.audio.AudioCommandResult.Success -> Unit
                is github.realtvop.aonsoku.plugins.audio.AudioCommandResult.Failure -> {
                    _state.update { it.copy(actionError = result.message) }
                }
            }
        }
    }

    private fun loginErrorMessage(result: AuthenticationResult): String = when (result.error) {
        "network_unreachable" -> "Could not reach the server"
        "auth_failed" -> "The server rejected these credentials"
        else -> result.error ?: "Login failed"
    }
}
