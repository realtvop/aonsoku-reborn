package github.realtvop.aonsoku.ui.overlays

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.ActionDivider
import github.realtvop.aonsoku.ui.components.ActionItem
import github.realtvop.aonsoku.ui.components.ActionSheet
import github.realtvop.aonsoku.ui.components.ListLoadingFooter
import github.realtvop.aonsoku.ui.components.ListMessage
import github.realtvop.aonsoku.ui.components.SheetTitle

/** Picks the playlist that songs are added to, or creates a new one for them. */
@Composable
fun AddToPlaylistSheet(overlay: Overlay.AddToPlaylist, controller: OverlayController) {
    val graph = LocalAppGraph.current
    var query by rememberSaveable { mutableStateOf("") }
    val playlists by produceState<List<Playlist>?>(initialValue = null) {
        value = runCatching { graph.library.playlistsNow() }.getOrDefault(emptyList())
    }
    val filtered = remember(playlists, query) {
        val needle = query.trim()
        playlists?.filter { needle.isEmpty() || it.name.contains(needle, ignoreCase = true) }
    }

    fun add(playlistId: String?) {
        val album = overlay.album
        when {
            album != null -> graph.actions.addAlbumToPlaylist(album, playlistId)
            playlistId == null ->
                graph.actions.createPlaylistWith(overlay.suggestedName, overlay.songIds)
            else -> graph.actions.addToPlaylist(playlistId, overlay.songIds)
        }
    }

    ActionSheet(onDismiss = controller::dismiss) {
        SheetTitle(t("options.playlist.add"))
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
            placeholder = { Text(t("options.playlist.search")) },
            leadingIcon = {
                Icon(Icons.Rounded.Search, contentDescription = null, Modifier.size(20.dp))
            },
            singleLine = true,
            shape = MaterialTheme.shapes.extraLarge,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        )
        ActionItem(
            icon = Icons.Rounded.Add,
            label = t("options.playlist.create"),
            onClick = { add(null) },
        )
        ActionDivider()
        when {
            filtered == null -> ListLoadingFooter()
            filtered.isEmpty() -> ListMessage(t("options.playlist.notFound"))
            else -> filtered.forEach { playlist ->
                ActionItem(
                    icon = Icons.AutoMirrored.Rounded.QueueMusic,
                    label = playlist.name,
                    onClick = { add(playlist.id) },
                )
            }
        }
    }
}
