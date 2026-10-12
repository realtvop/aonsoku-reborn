package github.realtvop.aonsoku.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.data.HomeSection
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.PinnedEntry
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.runSuspendCatching
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class HomeState(
    val loading: Boolean = true,
    val refreshing: Boolean = false,
    val carousel: List<Album> = emptyList(),
    val pinned: List<PinnedEntry> = emptyList(),
    val sections: Map<HomeSection, List<Album>> = emptyMap(),
) {
    val isEmpty: Boolean
        get() = carousel.isEmpty() && pinned.isEmpty() && sections.values.all { it.isEmpty() }
}

class HomeViewModel(private val graph: AppGraph) : ViewModel() {
    private val _state = MutableStateFlow(HomeState())
    private var loadJob: Job? = null

    val state: StateFlow<HomeState> = _state.asStateFlow()

    init {
        load()
        viewModelScope.launch {
            graph.library.changes.collect { change ->
                when (change) {
                    // A finished sync can fill a home page that was still empty.
                    LibraryChange.Library -> reloadSections(keepCarousel = !_state.value.isEmpty)
                    LibraryChange.Playlists -> reloadPinned()
                    else -> Unit
                }
            }
        }
        viewModelScope.launch {
            graph.settings.state.map { it.pinnedHome }.distinctUntilChanged().drop(1).collect {
                reloadPinned()
            }
        }
        viewModelScope.launch {
            // Coming back online fills in what could not be loaded before.
            graph.network.isOnline.drop(1).collect { online ->
                if (online && _state.value.isEmpty) load()
            }
        }
    }

    private fun load() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            fetch(includeCarousel = true)
            _state.update { it.copy(loading = false, refreshing = false) }
        }
    }

    private fun reloadSections(keepCarousel: Boolean) {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            fetch(includeCarousel = !keepCarousel)
            _state.update { it.copy(loading = false, refreshing = false) }
        }
    }

    private fun reloadPinned() {
        viewModelScope.launch {
            val pinned = runSuspendCatching {
                graph.library.pinnedItems(graph.settings.current.pinnedHome)
            }.getOrDefault(emptyList())
            _state.update { it.copy(pinned = pinned) }
        }
    }

    /** Pull to refresh: reload every section and start an incremental sync. */
    fun refresh() {
        if (_state.value.refreshing) return
        _state.update { it.copy(refreshing = true) }
        graph.sync.syncNow()
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val started = System.currentTimeMillis()
            fetch(includeCarousel = true)
            // Keep the indicator visible long enough to be noticed.
            delay((MIN_REFRESH_MS - (System.currentTimeMillis() - started)).coerceAtLeast(0))
            _state.update { it.copy(loading = false, refreshing = false) }
        }
    }

    private suspend fun fetch(includeCarousel: Boolean) = coroutineScope {
        val carousel: Deferred<List<Album>>? = if (includeCarousel) {
            async { runSuspendCatching { graph.library.carouselAlbums() }.getOrDefault(emptyList()) }
        } else {
            null
        }
        val pinned = async {
            runSuspendCatching { graph.library.pinnedItems(graph.settings.current.pinnedHome) }
                .getOrDefault(emptyList())
        }
        val sections = HomeSection.entries.map { section ->
            async {
                section to runSuspendCatching { graph.library.homeAlbums(section) }
                    .getOrDefault(emptyList())
            }
        }
        val loadedSections = sections.awaitAll().toMap()
        val loadedCarousel = carousel?.await()
        val loadedPinned = pinned.await()
        _state.update {
            it.copy(
                carousel = loadedCarousel ?: it.carousel,
                pinned = loadedPinned,
                sections = loadedSections,
            )
        }
    }

    private companion object {
        const val MIN_REFRESH_MS = 600L
    }
}
