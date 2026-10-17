package github.realtvop.aonsoku.ui.detail

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.Loadable
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.ListMessage
import github.realtvop.aonsoku.ui.components.LoadableSource
import github.realtvop.aonsoku.ui.components.SongRow
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.humanDuration
import github.realtvop.aonsoku.ui.components.rememberNowPlaying
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

class FavoritesViewModel(private val graph: AppGraph) : ViewModel() {
    private val source = LoadableSource(viewModelScope) { graph.library.favoriteSongs() }

    val songs: StateFlow<Loadable<List<Song>>> = source.state

    init {
        viewModelScope.launch {
            graph.library.changes.collect { change ->
                if (change == LibraryChange.Favorites || change == LibraryChange.Library) {
                    source.reload()
                }
            }
        }
        viewModelScope.launch {
            graph.network.isOnline.drop(1).collect { online -> if (online) source.reload() }
        }
    }
}

@Composable
fun FavoritesScreen() {
    val model = graphViewModel { FavoritesViewModel(it) }
    val loadable by model.songs.collectAsStateWithLifecycle()

    when (val current = loadable) {
        is Loadable.Ready -> FavoritesContent(current.value)
        // Favorites always resolve to a list; a failure shows the empty page.
        is Loadable.Failed -> FavoritesContent(emptyList())
        Loadable.Loading -> DetailLoading()
    }
}

@Composable
private fun FavoritesContent(songs: List<Song>) {
    val graph = LocalAppGraph.current
    val overlays = LocalOverlays.current
    val strings = LocalStrings.current
    val nowPlaying = rememberNowPlaying()
    val header = remember { DetailHeaderState() }

    val title = t("sidebar.favorites")
    val badges = buildList {
        if (songs.isNotEmpty()) {
            add(HeaderBadge(plural("favorites.songCount", songs.size)))
            val duration = strings.humanDuration(songs.sumOf { it.duration })
            add(HeaderBadge(t("favorites.duration", "duration" to duration)))
        }
    }
    val emptyMessage = t("favorites.noSongs")

    DetailPage(title = title, header = header) {
        item(key = "header", contentType = "header") {
            DetailHeader(
                state = header,
                type = t("favorites.headline"),
                title = title,
                icon = Icons.Rounded.FavoriteBorder,
                badges = badges,
            )
        }
        item(key = "actions", contentType = "actions") {
            DetailActions(
                state = header,
                name = title,
                enabled = songs.isNotEmpty(),
                onPlay = { graph.player.playSongs(songs, index = 0, sourceName = title) },
                onShuffle = {
                    graph.player.playSongs(songs, index = null, shuffle = true, sourceName = title)
                },
            )
        }

        if (songs.isEmpty()) {
            item(key = "empty") { ListMessage(emptyMessage) }
        }
        itemsIndexed(
            items = songs,
            key = { index, song -> "song-$index-${song.id}" },
            contentType = { _, _ -> "song" },
        ) { index, song ->
            SongRow(
                song = song,
                nowPlaying = nowPlaying,
                onClick = { graph.player.playSongs(songs, index, sourceName = title) },
                onMore = { overlays.show(Overlay.SongMenu(song)) },
            )
        }
        item(key = "end") { Spacer(Modifier.height(8.dp)) }
    }
}
