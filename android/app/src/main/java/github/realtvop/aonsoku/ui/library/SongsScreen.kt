package github.realtvop.aonsoku.ui.library

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Sort
import androidx.compose.material.icons.rounded.MusicNote
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
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.SongListRequest
import github.realtvop.aonsoku.data.SongOrder
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.ActionDivider
import github.realtvop.aonsoku.ui.components.ActionSheet
import github.realtvop.aonsoku.ui.components.ChoiceItem
import github.realtvop.aonsoku.ui.components.EmptyState
import github.realtvop.aonsoku.ui.components.ListLoadingFooter
import github.realtvop.aonsoku.ui.components.ListMessage
import github.realtvop.aonsoku.ui.components.ListSearchBar
import github.realtvop.aonsoku.ui.components.LocalSheetDismiss
import github.realtvop.aonsoku.ui.components.PageLoading
import github.realtvop.aonsoku.ui.components.PageTitle
import github.realtvop.aonsoku.ui.components.SongRow
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.rememberNowPlaying
import github.realtvop.aonsoku.ui.components.rememberTitleCollapsed
import github.realtvop.aonsoku.ui.components.subPageContentPadding
import github.realtvop.aonsoku.ui.navigation.SongsRoute
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

data class SongsState(
    val loading: Boolean = true,
    val songs: List<Song> = emptyList(),
    val total: Int = 0,
    val hasMore: Boolean = false,
    val loadingMore: Boolean = false,
    val query: String = "",
    val order: SongOrder = SongOrder.LastAdded,
    val ascending: Boolean = false,
)

class SongsViewModel(private val graph: AppGraph, private val route: SongsRoute) : ViewModel() {
    private val _state = MutableStateFlow(
        SongsState(
            query = route.query.orEmpty(),
            order = SongOrder.fromKey(graph.settings.current.songSort),
        ),
    )
    private var loadJob: Job? = null
    private var searchJob: Job? = null

    val state: StateFlow<SongsState> = _state.asStateFlow()

    val byArtist: Boolean get() = !route.artistId.isNullOrEmpty()

    init {
        reload()
        viewModelScope.launch {
            graph.library.changes.collect { if (it == LibraryChange.Library) reload() }
        }
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

    fun setOrder(order: SongOrder) {
        if (order == _state.value.order) return
        _state.update { it.copy(order = order) }
        graph.settings.update { it.copy(songSort = order.key) }
        reload()
    }

    fun setAscending(ascending: Boolean) {
        if (ascending == _state.value.ascending) return
        _state.update { it.copy(ascending = ascending) }
        reload()
    }

    private fun request(): SongListRequest {
        val current = _state.value
        return SongListRequest(
            query = current.query.trim(),
            artistId = route.artistId?.takeIf { it.isNotEmpty() },
            order = current.order,
            ascending = current.ascending,
        )
    }

    private fun reload() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val page = runCatching {
                graph.library.songs(request(), 0, LibraryRepository.SONG_PAGE_SIZE)
            }.getOrNull()
            val total = if (byArtist) page?.songs?.size ?: 0 else songCount(page?.total ?: 0)
            _state.update {
                it.copy(
                    loading = false,
                    loadingMore = false,
                    songs = page?.songs.orEmpty(),
                    total = total,
                    hasMore = page?.hasMore == true,
                )
            }
        }
    }

    /** The header shows the size of the whole library, as the web app does. */
    private suspend fun songCount(pageTotal: Int): Int =
        runCatching { graph.library.totalSongCount() }.getOrDefault(0).takeIf { it > 0 } ?: pageTotal

    fun loadMore() {
        val current = _state.value
        if (current.loading || current.loadingMore || !current.hasMore) return
        _state.update { it.copy(loadingMore = true) }
        loadJob = viewModelScope.launch {
            val page = runCatching {
                graph.library.songs(request(), current.songs.size, LibraryRepository.SONG_PAGE_SIZE)
            }.getOrNull()
            _state.update {
                it.copy(
                    loadingMore = false,
                    songs = it.songs + page?.songs.orEmpty(),
                    hasMore = page?.hasMore == true && page.songs.isNotEmpty(),
                )
            }
        }
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 500L
    }
}

@Composable
fun SongsScreen(route: SongsRoute) {
    val model = graphViewModel { SongsViewModel(it, route) }
    val state by model.state.collectAsStateWithLifecycle()
    val graph = LocalAppGraph.current
    val overlays = LocalOverlays.current
    val nowPlaying = rememberNowPlaying()
    val listState = rememberLazyListState()
    val collapsed by rememberTitleCollapsed(listState)
    var searchOpen by rememberSaveable { mutableStateOf(!route.query.isNullOrEmpty()) }
    var sortOpen by rememberSaveable { mutableStateOf(false) }

    val title = if (model.byArtist && !route.artistName.isNullOrEmpty()) {
        t("songs.list.byArtist", "artist" to route.artistName)
    } else {
        t("sidebar.songs")
    }
    val searching = state.query.isNotBlank()

    LoadMoreEffect(listState, state.songs.size, model::loadMore)

    Box(modifier = Modifier.fillMaxSize()) {
        when {
            state.loading && state.songs.isEmpty() -> PageLoading()
            state.songs.isEmpty() && !searching && !searchOpen -> EmptyState(
                title = title,
                description = t("common.noResults"),
                icon = Icons.Rounded.MusicNote,
                modifier = Modifier.fillMaxSize(),
            )
            else -> LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = subPageContentPadding(),
            ) {
                item(key = "title") {
                    PageTitle(title = title, count = state.total.toString()) {
                        if (!model.byArtist) {
                            IconButton(onClick = { searchOpen = !searchOpen }) {
                                Icon(
                                    Icons.Rounded.Search,
                                    contentDescription = t("songs.list.search.placeholder"),
                                )
                            }
                        }
                        IconButton(onClick = { sortOpen = true }) {
                            Icon(
                                Icons.AutoMirrored.Rounded.Sort,
                                contentDescription = t("table.sort.asc"),
                            )
                        }
                    }
                }
                item(key = "search") {
                    ListSearchBar(
                        open = searchOpen && !model.byArtist,
                        query = state.query,
                        onQueryChange = model::setQuery,
                        placeholder = t("songs.list.search.placeholder"),
                    )
                }
                if (state.songs.isEmpty()) {
                    item(key = "no-results") { ListMessage(t("common.noResults")) }
                }
                itemsIndexed(state.songs, key = { index, song -> "$index-${song.id}" }) { index, song ->
                    SongRow(
                        song = song,
                        nowPlaying = nowPlaying,
                        subtitle = listOf(song.artistLabel, song.album.orEmpty())
                            .filter { it.isNotEmpty() }
                            .joinToString(" • "),
                        onClick = {
                            graph.player.playSongs(state.songs, index, sourceName = title)
                        },
                        onMore = { overlays.show(Overlay.SongMenu(song)) },
                    )
                }
                if (state.loadingMore) item(key = "more") { ListLoadingFooter() }
            }
        }
        SubPageTopBar(title = title, collapsed = collapsed)
    }

    if (sortOpen) {
        SongSortSheet(
            order = state.order,
            ascending = state.ascending,
            onOrder = model::setOrder,
            onAscending = model::setAscending,
            onDismiss = { sortOpen = false },
        )
    }
}

/** Requests the next page once the list is scrolled close to its end. */
@Composable
fun LoadMoreEffect(state: LazyListState, itemCount: Int, onLoadMore: () -> Unit) {
    LaunchedEffect(state, itemCount) {
        snapshotFlow {
            val last = state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= state.layoutInfo.totalItemsCount - LOAD_MORE_THRESHOLD
        }.distinctUntilChanged().collect { nearEnd -> if (nearEnd) onLoadMore() }
    }
}

private const val LOAD_MORE_THRESHOLD = 12

@Composable
private fun SongSortSheet(
    order: SongOrder,
    ascending: Boolean,
    onOrder: (SongOrder) -> Unit,
    onAscending: (Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    ActionSheet(onDismiss = onDismiss) {
        val dismiss = LocalSheetDismiss.current
        SongOrder.entries.forEach { option ->
            ChoiceItem(
                label = t(option.labelKey),
                selected = option == order,
                onClick = { dismiss { onOrder(option) } },
            )
        }
        ActionDivider()
        ChoiceItem(
            label = t("table.sort.desc"),
            selected = !ascending,
            onClick = { dismiss { onAscending(false) } },
        )
        ChoiceItem(
            label = t("table.sort.asc"),
            selected = ascending,
            onClick = { dismiss { onAscending(true) } },
        )
    }
}
