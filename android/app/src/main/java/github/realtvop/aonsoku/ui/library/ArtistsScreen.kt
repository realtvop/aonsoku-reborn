package github.realtvop.aonsoku.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.EmptyState
import github.realtvop.aonsoku.ui.components.PageLoading
import github.realtvop.aonsoku.ui.components.PageTitle
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.rememberTitleCollapsed
import github.realtvop.aonsoku.ui.components.subPageContentPadding
import github.realtvop.aonsoku.ui.navigation.ArtistRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class ArtistsViewModel(private val graph: AppGraph) : ViewModel() {
    private val _artists = MutableStateFlow<List<Artist>?>(null)

    /** Null while the first load is running. */
    val artists: StateFlow<List<Artist>?> = _artists.asStateFlow()

    init {
        load()
        viewModelScope.launch {
            graph.library.changes.collect { if (it == LibraryChange.Library) load() }
        }
    }

    private fun load() {
        viewModelScope.launch {
            _artists.value = runCatching { graph.library.artists() }.getOrDefault(emptyList())
        }
    }
}

@Composable
fun ArtistsScreen() {
    val model = graphViewModel { ArtistsViewModel(it) }
    val artists by model.artists.collectAsStateWithLifecycle()
    val navigator = LocalNavigator.current
    val overlays = LocalOverlays.current
    val listState = rememberLazyListState()
    val collapsed by rememberTitleCollapsed(listState)
    val title = t("sidebar.artists")

    Box(modifier = Modifier.fillMaxSize()) {
        val list = artists
        when {
            list == null -> PageLoading()
            list.isEmpty() -> EmptyState(
                title = title,
                description = t("common.noResults"),
                icon = Icons.Rounded.Mic,
                modifier = Modifier.fillMaxSize(),
            )
            else -> LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = subPageContentPadding(),
            ) {
                item(key = "title") { PageTitle(title = title, count = list.size.toString()) }
                items(list, key = { it.id }) { artist ->
                    ArtistRow(
                        artist = artist,
                        onClick = { navigator.open(ArtistRoute(artist.id)) },
                        onMore = { overlays.show(Overlay.ArtistMenu(artist)) },
                    )
                }
            }
        }
        SubPageTopBar(title = title, collapsed = collapsed || artists.isNullOrEmpty())
    }
}

@Composable
private fun ArtistRow(artist: Artist, onClick: () -> Unit, onMore: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .height(60.dp)
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoverImage(
            art = CoverArt(artist.coverArt ?: artist.id),
            modifier = Modifier.size(44.dp),
            kind = CoverKind.Artist,
            shape = CircleShape,
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = artist.name,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = plural("artist.info.albumsCount", artist.albumCount),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        IconButton(onClick = onMore) {
            Icon(
                Icons.Rounded.MoreVert,
                contentDescription = t("artist.buttons.options", "artist" to artist.name),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
