package github.realtvop.aonsoku.ui.library

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.Loadable
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.LoadableSource
import github.realtvop.aonsoku.ui.components.RootHeader
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.navigation.AlbumsRoute
import github.realtvop.aonsoku.ui.navigation.ArtistsRoute
import github.realtvop.aonsoku.ui.navigation.FavoritesRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.PlaylistRoute
import github.realtvop.aonsoku.ui.navigation.RadiosRoute
import github.realtvop.aonsoku.ui.navigation.SongsRoute
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import github.realtvop.aonsoku.ui.shell.floatingBarsContentPadding
import kotlinx.coroutines.launch

class LibraryViewModel(graph: AppGraph) : ViewModel() {
    val playlists = LoadableSource(viewModelScope) { graph.library.playlists() }

    init {
        viewModelScope.launch {
            graph.library.changes.collect { change ->
                if (change == LibraryChange.Playlists || change == LibraryChange.Library) {
                    playlists.reload()
                }
            }
        }
    }
}

@Composable
fun LibraryScreen() {
    val model = graphViewModel { LibraryViewModel(it) }
    val playlists by model.playlists.state.collectAsStateWithLifecycle()
    val settings by LocalAppGraph.current.settings.state.collectAsStateWithLifecycle()
    val navigator = LocalNavigator.current
    val overlays = LocalOverlays.current

    Column(modifier = Modifier.fillMaxSize()) {
        RootHeader(title = t("sidebar.library"))
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = floatingBarsContentPadding(),
        ) {
            item(key = "artists") {
                LibraryRow(Icons.Rounded.Mic, t("sidebar.artists")) { navigator.open(ArtistsRoute) }
            }
            item(key = "songs") {
                LibraryRow(Icons.Rounded.MusicNote, t("sidebar.songs")) {
                    navigator.open(SongsRoute())
                }
            }
            item(key = "albums") {
                LibraryRow(Icons.Rounded.Album, t("sidebar.albums")) { navigator.open(AlbumsRoute()) }
            }
            item(key = "favorites") {
                LibraryRow(Icons.Rounded.Favorite, t("sidebar.favorites")) {
                    navigator.open(FavoritesRoute)
                }
            }
            if (!settings.hideRadios) {
                item(key = "radios") {
                    LibraryRow(Icons.Rounded.Radio, t("sidebar.radios")) {
                        navigator.open(RadiosRoute)
                    }
                }
            }
            item(key = "playlists-title") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 20.dp, end = 8.dp, top = 20.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = t("sidebar.playlists"),
                        style = MaterialTheme.typography.titleLarge,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { overlays.show(Overlay.PlaylistForm()) }) {
                        Icon(
                            Icons.Rounded.Add,
                            contentDescription = t("playlist.form.create.title"),
                        )
                    }
                }
            }
            val list = (playlists as? Loadable.Ready<List<Playlist>>)?.value
            when {
                list == null && playlists is Loadable.Loading -> Unit
                list.isNullOrEmpty() -> item(key = "playlists-empty") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp)
                            .clip(MaterialTheme.shapes.medium)
                            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                            .padding(vertical = 14.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = t("sidebar.emptyPlaylist"),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                else -> items(list, key = { "playlist-${it.id}" }) { playlist ->
                    LibraryRow(
                        icon = Icons.AutoMirrored.Rounded.QueueMusic,
                        label = playlist.name,
                        onLongClick = {
                            overlays.show(Overlay.PlaylistMenu(playlist, showPlay = true))
                        },
                        onClick = { navigator.open(PlaylistRoute(playlist.id)) },
                    )
                }
            }
        }
    }
}

@Composable
private fun LibraryRow(
    icon: ImageVector,
    label: String,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .clip(MaterialTheme.shapes.large)
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick?.let { action ->
                    {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        action()
                    }
                },
            )
            .height(56.dp)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(MaterialTheme.shapes.medium)
                .background(MaterialTheme.colorScheme.surfaceContainerHighest),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(14.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.bodyLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
