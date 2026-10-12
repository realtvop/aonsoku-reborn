package github.realtvop.aonsoku.ui.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.data.AlbumFilters
import github.realtvop.aonsoku.data.AlbumListRequest
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.ActionDivider
import github.realtvop.aonsoku.ui.components.ActionSheet
import github.realtvop.aonsoku.ui.components.AlbumCard
import github.realtvop.aonsoku.ui.components.ChoiceItem
import github.realtvop.aonsoku.ui.components.EmptyState
import github.realtvop.aonsoku.ui.components.ListLoadingFooter
import github.realtvop.aonsoku.ui.components.ListMessage
import github.realtvop.aonsoku.ui.components.ListSearchBar
import github.realtvop.aonsoku.ui.components.LocalSheetDismiss
import github.realtvop.aonsoku.ui.components.PageLoading
import github.realtvop.aonsoku.ui.components.PageTitle
import github.realtvop.aonsoku.ui.components.SheetTitle
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.rememberTitleCollapsed
import github.realtvop.aonsoku.ui.components.subPageContentPadding
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.AlbumsRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class AlbumsState(
    val loading: Boolean = true,
    val albums: List<Album> = emptyList(),
    val total: Int = 0,
    val loadingMore: Boolean = false,
    /** Filter chosen in the sheet (or given by the route); search overrides it. */
    val filter: String = AlbumFilters.RECENTLY_ADDED,
    val yearFilter: String = AlbumFilters.YEAR_OLDEST,
    val genre: String? = null,
    val artistId: String? = null,
    val artistName: String? = null,
    val query: String = "",
) {
    val hasMore: Boolean get() = albums.size < total

    val searching: Boolean get() = query.isNotBlank()
}

class AlbumsViewModel(private val graph: AppGraph, route: AlbumsRoute) : ViewModel() {
    private val randomSeed = System.nanoTime()
    private val _state: MutableStateFlow<AlbumsState>
    private var loadJob: Job? = null
    private var searchJob: Job? = null

    val state: StateFlow<AlbumsState>

    init {
        val saved = graph.settings.current.albumList
        val artistId = route.artistId?.takeIf { it.isNotEmpty() }
        val genre = route.genre?.takeIf { it.isNotEmpty() }
        val routeFilter = route.filter?.takeIf { it.isNotEmpty() && it != AlbumFilters.SEARCH }
        val filter = when {
            artistId != null -> AlbumFilters.DISCOGRAPHY
            genre != null -> AlbumFilters.BY_GENRE
            routeFilter != null -> routeFilter
            else -> saved.filter
        }
        _state = MutableStateFlow(
            AlbumsState(
                filter = filter,
                yearFilter = route.yearFilter?.takeIf { it.isNotEmpty() } ?: saved.yearFilter,
                genre = genre,
                artistId = artistId,
                artistName = route.artistName,
                query = route.query.orEmpty(),
            ),
        )
        state = _state.asStateFlow()
        reload()
        viewModelScope.launch {
            graph.library.changes.collect { if (it == LibraryChange.Library) reload() }
        }
    }

    /** Picks a filter from the sheet; artist and genre scopes are left behind. */
    fun setFilter(filter: String) {
        _state.update {
            it.copy(filter = filter, genre = null, artistId = null, artistName = null)
        }
        graph.settings.update { it.copy(albumList = it.albumList.copy(filter = filter)) }
        reload()
    }

    fun setYearFilter(yearFilter: String) {
        _state.update { it.copy(yearFilter = yearFilter) }
        graph.settings.update { it.copy(albumList = it.albumList.copy(yearFilter = yearFilter)) }
        reload()
    }

    fun setQuery(value: String) {
        if (value == _state.value.query) return
        _state.update { it.copy(query = value) }
        searchJob?.cancel()
        searchJob = viewModelScope.launch {
            if (value.isNotEmpty()) delay(SEARCH_DEBOUNCE_MS)
            reload()
        }
    }

    private fun request(): AlbumListRequest {
        val current = _state.value
        return if (current.searching) {
            AlbumListRequest(filter = AlbumFilters.SEARCH, query = current.query.trim())
        } else {
            AlbumListRequest(
                filter = current.filter,
                yearFilter = current.yearFilter,
                genre = current.genre,
                artistId = current.artistId,
                randomSeed = randomSeed,
            )
        }
    }

    private fun reload() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val page = runSuspendCatching {
                graph.library.albums(request(), 0, LibraryRepository.ALBUM_PAGE_SIZE)
            }.getOrNull()
            _state.update {
                it.copy(
                    loading = false,
                    loadingMore = false,
                    albums = page?.albums.orEmpty().distinctBy(Album::id),
                    total = maxOf(page?.total ?: 0, page?.albums?.size ?: 0),
                )
            }
        }
    }

    fun loadMore() {
        val current = _state.value
        if (current.loading || current.loadingMore || !current.hasMore) return
        _state.update { it.copy(loadingMore = true) }
        loadJob = viewModelScope.launch {
            val page = runSuspendCatching {
                graph.library.albums(request(), current.albums.size, LibraryRepository.ALBUM_PAGE_SIZE)
            }.getOrNull()
            _state.update {
                val merged = (it.albums + page?.albums.orEmpty()).distinctBy(Album::id)
                // A page that adds nothing ends the list, whatever the reported total.
                val grew = merged.size > it.albums.size
                it.copy(
                    loadingMore = false,
                    albums = merged,
                    total = if (grew) maxOf(page?.total ?: 0, merged.size) else merged.size,
                )
            }
        }
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 500L
    }
}

@Composable
fun AlbumsScreen(route: AlbumsRoute) {
    val model = graphViewModel { AlbumsViewModel(it, route) }
    val state by model.state.collectAsStateWithLifecycle()
    val navigator = LocalNavigator.current
    val overlays = LocalOverlays.current
    val gridState = rememberLazyGridState()
    val collapsed by rememberTitleCollapsed(gridState)
    var searchOpen by rememberSaveable { mutableStateOf(!route.query.isNullOrEmpty()) }
    var filterOpen by rememberSaveable { mutableStateOf(false) }

    val title = if (state.artistId != null && !state.artistName.isNullOrEmpty()) {
        t("album.list.header.albumsByArtist", "artist" to state.artistName)
    } else {
        t("sidebar.albums")
    }
    val count = listOfNotNull(
        state.total.toString(),
        state.genre?.takeIf { state.filter == AlbumFilters.BY_GENRE && !state.searching },
    ).joinToString(" • ")

    GridLoadMoreEffect(gridState, state.albums.size, model::loadMore)

    Box(modifier = Modifier.fillMaxSize()) {
        when {
            state.loading && state.albums.isEmpty() -> PageLoading()
            state.albums.isEmpty() && !state.searching && !searchOpen &&
                state.filter == AlbumFilters.RECENTLY_ADDED -> EmptyState(
                title = t("album.list.empty.title"),
                description = t("album.list.empty.info"),
                icon = Icons.Rounded.Album,
                modifier = Modifier.fillMaxSize(),
            )
            else -> {
                val padding = subPageContentPadding()
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(minSize = 148.dp),
                    state = gridState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = GridEdge,
                        end = GridEdge,
                        top = padding.calculateTopPadding(),
                        bottom = padding.calculateBottomPadding(),
                    ),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    item(key = "title", span = { GridItemSpan(maxLineSpan) }) {
                        PageTitle(title = title, count = count, modifier = Modifier.fullBleed()) {
                            IconButton(onClick = { searchOpen = !searchOpen }) {
                                Icon(
                                    Icons.Rounded.Search,
                                    contentDescription = t("album.list.search.placeholder"),
                                )
                            }
                            IconButton(onClick = { filterOpen = true }) {
                                Icon(
                                    Icons.Rounded.FilterList,
                                    contentDescription = t("album.list.filter.label"),
                                )
                            }
                        }
                    }
                    item(key = "search", span = { GridItemSpan(maxLineSpan) }) {
                        ListSearchBar(
                            open = searchOpen,
                            query = state.query,
                            onQueryChange = model::setQuery,
                            placeholder = t("album.list.search.placeholder"),
                            modifier = Modifier.fullBleed(),
                        )
                    }
                    if (state.albums.isEmpty()) {
                        item(key = "no-results", span = { GridItemSpan(maxLineSpan) }) {
                            ListMessage(
                                t(if (state.searching) "common.noResults" else "album.list.empty.info"),
                            )
                        }
                    }
                    items(state.albums, key = { it.id }) { album ->
                        AlbumCard(
                            album = album,
                            onClick = { navigator.open(AlbumRoute(album.id)) },
                            onLongClick = { overlays.show(Overlay.AlbumMenu(album)) },
                        )
                    }
                    if (state.loadingMore) {
                        item(key = "more", span = { GridItemSpan(maxLineSpan) }) {
                            ListLoadingFooter()
                        }
                    }
                }
            }
        }
        SubPageTopBar(title = title, collapsed = collapsed)
    }

    if (filterOpen) {
        AlbumFilterSheet(
            filter = state.filter.takeIf { state.artistId == null && state.genre == null },
            yearFilter = state.yearFilter,
            onFilter = model::setFilter,
            onYearFilter = model::setYearFilter,
            onDismiss = { filterOpen = false },
        )
    }
}

private val GridEdge = 16.dp

/** Lets a full-span grid item ignore the horizontal content padding of the grid. */
@Composable
private fun Modifier.fullBleed(): Modifier {
    val direction = LocalLayoutDirection.current
    val padding = PaddingValues(horizontal = GridEdge)
    val start = padding.calculateStartPadding(direction)
    val end = padding.calculateEndPadding(direction)
    return layout { measurable, constraints ->
        val extra = (start + end).roundToPx()
        val placeable = measurable.measure(
            constraints.copy(maxWidth = constraints.maxWidth + extra),
        )
        layout(constraints.maxWidth, placeable.height) {
            placeable.place(-start.roundToPx(), 0)
        }
    }
}

@Composable
private fun GridLoadMoreEffect(state: LazyGridState, itemCount: Int, onLoadMore: () -> Unit) {
    LaunchedEffect(state, itemCount) {
        snapshotFlow {
            val last = state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= state.layoutInfo.totalItemsCount - GRID_LOAD_MORE_THRESHOLD
        }.distinctUntilChanged().collect { nearEnd -> if (nearEnd) onLoadMore() }
    }
}

private const val GRID_LOAD_MORE_THRESHOLD = 16

@Composable
private fun AlbumFilterSheet(
    filter: String?,
    yearFilter: String,
    onFilter: (String) -> Unit,
    onYearFilter: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ActionSheet(onDismiss = onDismiss) {
        val dismiss = LocalSheetDismiss.current
        SheetTitle(t("album.list.filter.label"))
        AlbumFilters.selectable.forEach { (key, labelKey) ->
            ChoiceItem(
                label = t(labelKey),
                selected = key == filter,
                onClick = {
                    // The release-year filter keeps the sheet open to pick an order.
                    if (key == AlbumFilters.BY_YEAR) onFilter(key) else dismiss { onFilter(key) }
                },
            )
        }
        if (filter == AlbumFilters.BY_YEAR) {
            ActionDivider()
            ChoiceItem(
                label = t("album.list.filter.year.oldest"),
                selected = yearFilter == AlbumFilters.YEAR_OLDEST,
                onClick = { dismiss { onYearFilter(AlbumFilters.YEAR_OLDEST) } },
            )
            ChoiceItem(
                label = t("album.list.filter.year.newest"),
                selected = yearFilter == AlbumFilters.YEAR_NEWEST,
                onClick = { dismiss { onYearFilter(AlbumFilters.YEAR_NEWEST) } },
            )
        }
    }
}
