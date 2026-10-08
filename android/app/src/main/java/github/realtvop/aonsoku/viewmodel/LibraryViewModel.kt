package github.realtvop.aonsoku.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.data.AlbumFilter
import github.realtvop.aonsoku.plugins.data.ArtistFilter
import github.realtvop.aonsoku.plugins.data.LibraryPagination
import github.realtvop.aonsoku.plugins.data.SongFilter
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class LibraryViewModel(application: Application) : AndroidViewModel(application) {
    private val libraryService = AppServices.getInstance(application).library

    private val _playlists = MutableStateFlow<List<PlaylistEntity>>(emptyList())
    val playlists: StateFlow<List<PlaylistEntity>> = _playlists.asStateFlow()

    private val _artistCount = MutableStateFlow(0)
    val artistCount: StateFlow<Int> = _artistCount.asStateFlow()

    private val _albumCount = MutableStateFlow(0)
    val albumCount: StateFlow<Int> = _albumCount.asStateFlow()

    private val _songCount = MutableStateFlow(0)
    val songCount: StateFlow<Int> = _songCount.asStateFlow()

    private val _favoriteCount = MutableStateFlow(0)
    val favoriteCount: StateFlow<Int> = _favoriteCount.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    init {
        loadData()
        viewModelScope.launch {
            libraryService.dataChanges.collect {
                loadData()
            }
        }
    }

    fun loadData() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val playlistsPage = libraryService.getPlaylists(LibraryPagination(limit = 100, offset = 0))
                _playlists.value = playlistsPage.items

                val artists = libraryService.getArtists(
                    pagination = LibraryPagination(limit = 1, offset = 0),
                    filter = ArtistFilter(),
                )
                _artistCount.value = artists.total

                val albums = libraryService.getAlbums(
                    pagination = LibraryPagination(limit = 1, offset = 0),
                    filter = AlbumFilter(),
                )
                _albumCount.value = albums.total

                val songs = libraryService.getSongs(
                    pagination = LibraryPagination(limit = 1, offset = 0),
                    filter = SongFilter(),
                )
                _songCount.value = songs.total

                val favorites = libraryService.getSongs(
                    pagination = LibraryPagination(limit = 1, offset = 0),
                    filter = SongFilter(starredOnly = true),
                )
                _favoriteCount.value = favorites.total
            } catch (_: Exception) {
            } finally {
                _isLoading.value = false
            }
        }
    }
}
