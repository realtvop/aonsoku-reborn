package github.realtvop.aonsoku.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.data.HomeSection
import github.realtvop.aonsoku.data.HomeSnapshot
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.PinnedEntry
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.runSuspendCatching
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
    val carouselLoading: Boolean = true,
    val loadingSections: Set<HomeSection> = HomeSection.entries.toSet(),
    val carousel: List<Album> = emptyList(),
    val pinned: List<PinnedEntry> = emptyList(),
    val sections: Map<HomeSection, List<Album>> = emptyMap(),
) {
    val isEmpty: Boolean
        get() = carousel.isEmpty() && pinned.isEmpty() && sections.values.all { it.isEmpty() }
}

class HomeViewModel(
    private val graph: AppGraph,
    private val now: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    private val _state = MutableStateFlow(HomeState())
    private var loadJob: Job? = null
    private var cacheOwner: String? = null
    private var restoredCache = false
    private var hasCarousel = false
    private var carouselUpdatedAt: Long? = null
    private var exploreUpdatedAt: Long? = null

    val state: StateFlow<HomeState> = _state.asStateFlow()

    init {
        load()
        viewModelScope.launch {
            graph.library.changes.collect { change ->
                when (change) {
                    // A finished sync can fill a home page that was still empty.
                    LibraryChange.Library -> if (!_state.value.refreshing) reloadSections()
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
                if (online && !_state.value.refreshing) load()
            }
        }
    }

    private fun load() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            fetch(refreshRandom = false)
            _state.update { it.copy(loading = false, refreshing = false) }
        }
    }

    private fun reloadSections() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            fetch(refreshRandom = false)
            _state.update { it.copy(loading = false, refreshing = false) }
        }
    }

    private fun reloadPinned() {
        viewModelScope.launch {
            val owner = accountKey() ?: return@launch
            reloadPinnedNow(owner)
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
            fetch(refreshRandom = true)
            // Keep the indicator visible long enough to be noticed.
            delay((MIN_REFRESH_MS - (System.currentTimeMillis() - started)).coerceAtLeast(0))
            _state.update { it.copy(loading = false, refreshing = false) }
        }
    }

    private fun accountKey(): String? {
        val credentials = graph.session.credentials ?: return null
        val server = graph.settings.current.server.primaryUrl.ifEmpty { credentials.serverUrl }
        return "${server.length}:$server${credentials.username}"
    }

    private suspend fun restoreCache(owner: String) {
        val snapshot = runSuspendCatching { graph.homeCache.read(owner) }.getOrNull()
        val carousel = snapshot?.carousel ?: runSuspendCatching {
            graph.library.cachedCarouselAlbums().takeIf { it.isNotEmpty() }
        }.getOrNull()
        val sections = HomeSection.entries.mapNotNull { section ->
            val albums = snapshot?.sections?.get(section.name) ?: runSuspendCatching {
                graph.library.cachedHomeAlbums(section).takeIf { it.isNotEmpty() }
            }.getOrNull()
            albums?.let { section to it }
        }.toMap()
        val pinned = runSuspendCatching {
            graph.library.pinnedItems(graph.settings.current.pinnedHome, localOnly = true)
        }.getOrDefault(emptyList())
        if (accountKey() != owner) return
        hasCarousel = carousel != null
        carouselUpdatedAt = snapshot?.carouselUpdatedAt ?: now().takeIf { hasCarousel }
        exploreUpdatedAt = snapshot?.exploreUpdatedAt ?: now().takeIf { HomeSection.Explore in sections }
        _state.update {
            it.copy(
                loading = false,
                carousel = carousel.orEmpty(),
                pinned = pinned,
                sections = sections,
                carouselLoading = !hasCarousel,
                loadingSections = HomeSection.entries.filter { it !in sections }.toSet(),
            )
        }
        restoredCache = true
        persistCache(owner)
    }

    private suspend fun fetch(refreshRandom: Boolean) = coroutineScope {
        val owner = accountKey() ?: return@coroutineScope
        if (cacheOwner != owner) {
            cacheOwner = owner
            restoredCache = false
            hasCarousel = false
            carouselUpdatedAt = null
            exploreUpdatedAt = null
            _state.value = HomeState()
        }
        if (!restoredCache) restoreCache(owner)
        if (accountKey() != owner) return@coroutineScope
        if (!graph.network.online) {
            _state.update { it.copy(carouselLoading = false, loadingSections = emptySet()) }
            return@coroutineScope
        }
        val refreshCarousel = refreshRandom || _state.value.carousel.isEmpty() || expired(carouselUpdatedAt)
        val refreshExplore = refreshRandom || _state.value.sections[HomeSection.Explore].isNullOrEmpty() || expired(exploreUpdatedAt)
        _state.update {
            it.copy(
                carouselLoading = refreshCarousel && !hasCarousel,
                loadingSections = HomeSection.entries.filter { section -> section !in it.sections }.toSet(),
            )
        }
        val tasks = HomeSection.entries.filter { it != HomeSection.Explore || refreshExplore }.map { section ->
            async {
                val albums = runSuspendCatching {
                    graph.library.homeAlbums(section, fallbackToLocal = false)
                }.getOrNull()
                if (accountKey() == owner) {
                    if (section == HomeSection.Explore && albums != null) exploreUpdatedAt = now()
                    _state.update {
                        it.copy(
                            sections = if (albums != null) it.sections + (section to albums) else it.sections,
                            loadingSections = it.loadingSections - section,
                        )
                    }
                }
            }
        } + listOf(
            async {
                if (refreshCarousel) {
                    val albums = runSuspendCatching {
                        graph.library.carouselAlbums(fallbackToLocal = false)
                    }.getOrNull()
                    if (accountKey() == owner) {
                        if (albums != null) {
                            hasCarousel = true
                            carouselUpdatedAt = now()
                        }
                        _state.update {
                            it.copy(carousel = albums ?: it.carousel, carouselLoading = false)
                        }
                    }
                }
            },
            async { reloadPinnedNow(owner) },
        )
        tasks.awaitAll()
        if (accountKey() != owner) return@coroutineScope
        persistCache(owner)
    }

    private fun expired(updatedAt: Long?): Boolean =
        updatedAt == null || now() - updatedAt >= RANDOM_CACHE_LIFETIME_MS

    private suspend fun persistCache(owner: String) {
        if (accountKey() != owner) return
        val current = _state.value
        runSuspendCatching {
            graph.homeCache.write(HomeSnapshot(
                accountKey = owner,
                carousel = current.carousel.takeIf { hasCarousel },
                sections = current.sections.mapKeys { it.key.name },
                carouselUpdatedAt = carouselUpdatedAt,
                exploreUpdatedAt = exploreUpdatedAt,
            ))
        }
    }

    private suspend fun reloadPinnedNow(owner: String) {
        val pins = runSuspendCatching {
            graph.library.pinnedItems(graph.settings.current.pinnedHome)
        }.getOrNull() ?: return
        if (accountKey() == owner) _state.update { it.copy(pinned = pins) }
    }

    private companion object {
        const val MIN_REFRESH_MS = 600L
        const val RANDOM_CACHE_LIFETIME_MS = 24 * 60 * 60 * 1000L
    }
}
