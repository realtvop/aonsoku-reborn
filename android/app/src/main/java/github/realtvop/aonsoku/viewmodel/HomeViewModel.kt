package github.realtvop.aonsoku.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.data.AlbumFilter
import github.realtvop.aonsoku.plugins.data.LibraryPagination
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class HomeViewModel(application: Application) : AndroidViewModel(application) {
    private val libraryService = AppServices.getInstance(application).library

    private val _carouselAlbums = MutableStateFlow<List<AlbumEntity>>(emptyList())
    val carouselAlbums: StateFlow<List<AlbumEntity>> = _carouselAlbums.asStateFlow()

    private val _recentlyAdded = MutableStateFlow<List<AlbumEntity>>(emptyList())
    val recentlyAdded: StateFlow<List<AlbumEntity>> = _recentlyAdded.asStateFlow()

    private val _mostPlayed = MutableStateFlow<List<AlbumEntity>>(emptyList())
    val mostPlayed: StateFlow<List<AlbumEntity>> = _mostPlayed.asStateFlow()

    private val _explore = MutableStateFlow<List<AlbumEntity>>(emptyList())
    val explore: StateFlow<List<AlbumEntity>> = _explore.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    init {
        loadHomeData()
        viewModelScope.launch {
            libraryService.dataChanges.collect { change ->
                if (change.tables.contains("album") || change.tables.contains("song")) {
                    loadHomeData()
                }
            }
        }
    }

    fun loadHomeData() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val addedPage = libraryService.getAlbums(
                    pagination = LibraryPagination(limit = 10, offset = 0),
                    filter = AlbumFilter(sortBy = "created"),
                )
                _recentlyAdded.value = addedPage.items

                val playedPage = libraryService.getAlbums(
                    pagination = LibraryPagination(limit = 10, offset = 0),
                    filter = AlbumFilter(sortBy = "playCount"),
                )
                _mostPlayed.value = playedPage.items

                val allPage = libraryService.getAlbums(
                    pagination = LibraryPagination(limit = 20, offset = 0),
                    filter = AlbumFilter(),
                )
                val allItems = allPage.items
                _explore.value = allItems.shuffled().take(10)
                _carouselAlbums.value = (addedPage.items.take(3) + allItems.take(2)).distinctBy { it.id }
            } catch (_: Exception) {
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun refresh() {
        libraryService.syncIncremental()
        loadHomeData()
    }
}
