package github.realtvop.aonsoku.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.data.LibrarySearchResult
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class SearchViewModel(application: Application) : AndroidViewModel(application) {
    private val libraryService = AppServices.getInstance(application).library

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    private val _artists = MutableStateFlow<List<ArtistEntity>>(emptyList())
    val artists: StateFlow<List<ArtistEntity>> = _artists.asStateFlow()

    private val _albums = MutableStateFlow<List<AlbumEntity>>(emptyList())
    val albums: StateFlow<List<AlbumEntity>> = _albums.asStateFlow()

    private val _songs = MutableStateFlow<List<SongEntity>>(emptyList())
    val songs: StateFlow<List<SongEntity>> = _songs.asStateFlow()

    private val _isSearching = MutableStateFlow(false)
    val isSearching: StateFlow<Boolean> = _isSearching.asStateFlow()

    private var searchJob: Job? = null

    fun onQueryChange(newQuery: String) {
        _query.value = newQuery
        searchJob?.cancel()

        if (newQuery.isBlank()) {
            _artists.value = emptyList()
            _albums.value = emptyList()
            _songs.value = emptyList()
            _isSearching.value = false
            return
        }

        searchJob = viewModelScope.launch {
            delay(200) // Debounce
            _isSearching.value = true
            try {
                val results: LibrarySearchResult = libraryService.search(
                    query = newQuery.trim(),
                    artistCount = 10,
                    albumCount = 10,
                    songCount = 30,
                )
                _artists.value = results.artists
                _albums.value = results.albums
                _songs.value = results.songs
            } catch (_: Exception) {
            } finally {
                _isSearching.value = false
            }
        }
    }

    fun clearQuery() {
        onQueryChange("")
    }
}
