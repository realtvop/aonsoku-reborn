package github.realtvop.aonsoku.ui.search

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.AlbumFilters
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.SearchResult
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.ListMessage
import github.realtvop.aonsoku.ui.components.RootHeader
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.songCoverArt
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.AlbumsRoute
import github.realtvop.aonsoku.ui.navigation.ArtistRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.SongsRoute
import github.realtvop.aonsoku.ui.shell.floatingBarsContentPadding
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class SearchState(
    val query: String = "",
    /** The query the shown [result] belongs to. */
    val searched: String = "",
    val result: SearchResult? = null,
)

class SearchViewModel(private val graph: AppGraph) : ViewModel() {
    private val _state = MutableStateFlow(SearchState())
    private val submitted = MutableStateFlow("")

    val state: StateFlow<SearchState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            submitted
                .debounce { if (it.isEmpty()) 0L else DEBOUNCE_MS }
                .distinctUntilChanged()
                .mapLatest { query ->
                    val result = if (isSearchable(query)) {
                        runCatching { graph.library.search(query, RESULT_COUNT) }.getOrNull()
                    } else {
                        null
                    }
                    query to result
                }
                .collect { (query, result) ->
                    _state.update { it.copy(searched = query, result = result) }
                }
        }
    }

    fun onQueryChange(value: String) {
        _state.update { it.copy(query = value) }
        submitted.value = value.trim()
    }

    companion object {
        const val RESULT_COUNT = 6
        private const val DEBOUNCE_MS = 500L

        /** Matches the web rule: at least three UTF-8 bytes. */
        fun isSearchable(query: String): Boolean = query.toByteArray(Charsets.UTF_8).size >= 3
    }
}

@Composable
fun SearchScreen() {
    val model = graphViewModel { SearchViewModel(it) }
    val state by model.state.collectAsStateWithLifecycle()
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val focusManager = LocalFocusManager.current
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        if (state.query.isEmpty()) runCatching { focusRequester.requestFocus() }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        RootHeader(title = t("sidebar.miniSearch"))
        TextField(
            value = state.query,
            onValueChange = model::onQueryChange,
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, bottom = 8.dp)
                .focusRequester(focusRequester),
            placeholder = {
                Text(
                    t("command.inputPlaceholder"),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
            trailingIcon = if (state.query.isNotEmpty()) {
                {
                    IconButton(onClick = { model.onQueryChange("") }) {
                        Icon(Icons.Rounded.Close, contentDescription = t("generic.clear"))
                    }
                }
            } else {
                null
            },
            singleLine = true,
            shape = CircleShape,
            colors = TextFieldDefaults.colors(
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                disabledIndicatorColor = Color.Transparent,
                focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            ),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Search,
            ),
            keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
        )

        val result = state.result
        val query = state.searched
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = floatingBarsContentPadding(),
        ) {
            if (result != null && result.isEmpty) {
                item(key = "no-results") { ListMessage(t("command.noResults")) }
            }
            if (result != null && result.album.isNotEmpty()) {
                item(key = "albums-title") {
                    ResultSectionTitle(t("sidebar.albums")) {
                        navigator.open(AlbumsRoute(filter = AlbumFilters.SEARCH, query = query))
                    }
                }
                items(result.album, key = { "album-${it.id}" }) { album ->
                    ResultRow(
                        art = CoverArt(album.coverArt ?: album.id),
                        kind = CoverKind.Album,
                        title = album.name,
                        subtitle = album.artistLabel,
                        onClick = { navigator.open(AlbumRoute(album.id)) },
                        onPlay = { graph.actions.playAlbum(album) },
                    )
                }
            }
            if (result != null && result.song.isNotEmpty()) {
                item(key = "songs-title") {
                    ResultSectionTitle(t("sidebar.songs")) {
                        navigator.open(SongsRoute(query = query))
                    }
                }
                items(result.song, key = { "song-${it.id}" }) { song ->
                    ResultRow(
                        art = songCoverArt(song),
                        kind = CoverKind.Song,
                        title = song.title,
                        subtitle = song.artistLabel,
                        onClick = {
                            song.albumId?.takeIf { it.isNotEmpty() }?.let {
                                navigator.open(AlbumRoute(it))
                            } ?: graph.player.playSong(song)
                        },
                        onPlay = { graph.player.playSong(song) },
                    )
                }
            }
            if (result != null && result.artist.isNotEmpty()) {
                item(key = "artists-title") { ResultSectionTitle(t("sidebar.artists"), null) }
                items(result.artist, key = { "artist-${it.id}" }) { artist ->
                    ResultRow(
                        art = CoverArt(artist.coverArt ?: artist.id),
                        kind = CoverKind.Artist,
                        title = artist.name,
                        subtitle = plural("artist.info.albumsCount", artist.albumCount),
                        onClick = { navigator.open(ArtistRoute(artist.id)) },
                        onPlay = { graph.actions.playArtist(artist.id, artist.name) },
                    )
                }
            }
        }
    }
}

@Composable
private fun ResultSectionTitle(title: String, onSeeMore: (() -> Unit)?) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = 44.dp)
            .padding(start = 20.dp, end = 8.dp, top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title.uppercase(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        if (onSeeMore != null) {
            TextButton(onClick = onSeeMore) {
                Text(t("generic.seeMore"), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun ResultRow(
    art: CoverArt,
    kind: CoverKind,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    onPlay: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .defaultMinSize(minHeight = 60.dp)
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoverImage(
            art = art,
            modifier = Modifier.size(44.dp),
            kind = kind,
            shape = if (kind == CoverKind.Artist) CircleShape else MaterialTheme.shapes.small,
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onPlay) {
            Icon(
                Icons.Rounded.PlayArrow,
                contentDescription = t("options.play"),
                modifier = Modifier.size(22.dp),
            )
        }
    }
}
