package github.realtvop.aonsoku.ui.detail

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.itemsIndexed
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
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.QueueSource
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.ListMessage
import github.realtvop.aonsoku.ui.components.LoadableSource
import github.realtvop.aonsoku.ui.components.SongRow
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.humanDuration
import github.realtvop.aonsoku.ui.components.rememberNowPlaying
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.PlaylistRoute
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

class PlaylistViewModel(private val graph: AppGraph, playlistId: String) : ViewModel() {
    private val source = LoadableSource(viewModelScope) { graph.library.playlist(playlistId) }
    private var deleted = false

    val playlist: StateFlow<Loadable<Playlist>> = source.state

    init {
        viewModelScope.launch {
            graph.library.changes.collect { change ->
                val affected = change == LibraryChange.Playlists || change == LibraryChange.Library
                if (affected && !deleted) source.reload()
            }
        }
        viewModelScope.launch {
            // Coming back online loads a playlist that was not available offline.
            graph.network.isOnline.drop(1).collect { online ->
                if (online && source.value == null && !deleted) source.reload()
            }
        }
    }

    /** The playlist was deleted from this page; keep showing it while the page closes. */
    fun onDeleted() {
        deleted = true
        source.stop()
    }
}

@Composable
fun PlaylistScreen(route: PlaylistRoute) {
    val model = graphViewModel { PlaylistViewModel(it, route.id) }
    val loadable by model.playlist.collectAsStateWithLifecycle()

    when (val current = loadable) {
        is Loadable.Ready -> PlaylistContent(current.value, onDeleted = model::onDeleted)
        is Loadable.Failed -> DetailFailure(current)
        Loadable.Loading -> DetailLoading()
    }
}

@Composable
private fun PlaylistContent(playlist: Playlist, onDeleted: () -> Unit) {
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val overlays = LocalOverlays.current
    val strings = LocalStrings.current
    val nowPlaying = rememberNowPlaying()
    val header = remember(playlist.id) { DetailHeaderState() }

    val songs = playlist.entry.orEmpty()
    val hasSongs = playlist.songCount > 0 || songs.isNotEmpty()
    val badges = buildList {
        if (hasSongs) {
            val count = if (songs.isNotEmpty()) songs.size else playlist.songCount
            add(HeaderBadge(plural("playlist.songCount", count)))
            val duration = strings.humanDuration(playlist.duration)
            add(HeaderBadge(t("playlist.duration", "duration" to duration)))
        }
    }
    val emptyMessage = t("playlist.noSongList")

    DetailPage(title = playlist.name, header = header) {
        item(key = "header", contentType = "header") {
            DetailHeader(
                state = header,
                type = t("playlist.headline"),
                title = playlist.name,
                // An empty playlist has no artwork of its own.
                art = CoverArt(playlist.coverArt?.takeIf { hasSongs }),
                kind = CoverKind.Playlist,
                subtitle = playlist.comment,
                badges = badges,
            )
        }
        item(key = "actions", contentType = "actions") {
            DetailActions(
                state = header,
                name = playlist.name,
                enabled = songs.isNotEmpty(),
                onPlay = { graph.actions.playPlaylist(playlist) },
                onShuffle = { graph.actions.playPlaylist(playlist, shuffle = true) },
                onMore = {
                    overlays.show(
                        Overlay.PlaylistMenu(
                            playlist = playlist,
                            onDeleted = {
                                onDeleted()
                                navigator.back()
                            },
                        ),
                    )
                },
            )
        }

        if (songs.isEmpty()) {
            item(key = "empty") { ListMessage(emptyMessage) }
        }
        itemsIndexed(
            items = songs,
            // A playlist may contain the same song more than once.
            key = { index, song -> "song-$index-${song.id}" },
            contentType = { _, _ -> "song" },
        ) { index, song ->
            SongRow(
                song = song,
                nowPlaying = nowPlaying,
                onClick = {
                    graph.player.playSongs(
                        songs = songs,
                        index = index,
                        source = QueueSource.playlist(playlist.id),
                        sourceName = playlist.name,
                    )
                },
                onMore = {
                    overlays.show(
                        Overlay.SongMenu(song, playlistId = playlist.id, playlistIndex = index),
                    )
                },
            )
        }
        item(key = "end") { Spacer(Modifier.height(8.dp)) }
    }
}
