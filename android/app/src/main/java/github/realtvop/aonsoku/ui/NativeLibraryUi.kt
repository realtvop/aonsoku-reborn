@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package github.realtvop.aonsoku.ui

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.plugins.audio.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun NativeItemMenu(model: AonsokuViewModel, item: LibraryItem, dismiss: () -> Unit) {
    val context = LocalContext.current
    ModalBottomSheet(dismiss) {
        LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
            item { Text(item.title, Modifier.padding(24.dp), style = MaterialTheme.typography.headlineSmall) }
            if (item.kind != "cover") item { ActionRow("Play", Icons.Default.PlayArrow) { model.playItem(item); dismiss() } }
            if (item.kind in listOf("album", "playlist")) item { ActionRow("Shuffle", Icons.Default.Shuffle) { model.playItem(item, true); dismiss() } }
            if (item.kind in listOf("song", "album", "playlist")) {
                item { ActionRow("Play next", Icons.AutoMirrored.Filled.PlaylistPlay) { model.launch { model.command(AudioCommand.AddSongsById(model.songIds(item), "next")) }; dismiss() } }
                item { ActionRow("Add to queue", Icons.AutoMirrored.Filled.PlaylistAdd) { model.launch { model.command(AudioCommand.AddSongsById(model.songIds(item), "last")) }; dismiss() } }
                item { ActionRow("Download", Icons.Default.Download) { model.download(item); dismiss() } }
                item { ActionRow("Add to playlist", Icons.Default.LibraryAdd) { model.launch { model.addToPlaylist(model.songIds(item)) }; dismiss() } }
            }
            if (item.kind in listOf("song", "album", "artist")) item { ActionRow(if (item.starred) "Remove from favorites" else "Add to favorites", Icons.Default.Favorite) { model.favorite(item); dismiss() } }
            if (item.kind in listOf("album", "playlist")) item { ActionRow("Pin or unpin on Home", Icons.Default.PushPin) { model.pin(item); dismiss() } }
            if (item.kind == "cover") item { ActionRow("Delete cached image", Icons.Default.Delete) { model.launch { model.services.library.deleteCoverImage(item.id); model.reload() }; dismiss() } }
            if (model.page.value.route == "history") item { ActionRow("Remove from history", Icons.Default.History) { model.launch { val rows = model.services.preferences.getPlayHistory(10000).toMutableList(); val index = item.position ?: return@launch; val removed = org.json.JSONObject(rows.removeAt(index)); removed.optString("eventId").takeIf(String::isNotBlank)?.let { model.coordinator.enqueueHistory(org.json.JSONObject().put("kind", "delete_one").put("eventId", it)) }; model.services.preferences.replacePlayHistory(rows); model.reload() }; dismiss() } }
            if (item.kind == "song") {
                item { ActionRow("Song information", Icons.Default.Info) { val s = item.song; model.dialog.value = NativeDialog.Info(item.title, listOf("Artist: ${s?.artist.orEmpty()}", "Album: ${s?.album.orEmpty()}", "Duration: ${formatTime(s?.duration?.toDouble() ?: 0.0)}", "Track: ${s?.track ?: 0}", "Disc: ${s?.discNumber ?: 0}", "Year: ${s?.year ?: 0}", "Genre: ${s?.genre.orEmpty()}", "Format: ${s?.suffix.orEmpty()} · ${s?.bitRate ?: 0} kbps", "Path: ${s?.path.orEmpty()}", s?.comment.orEmpty()).joinToString("\n")); dismiss() } }
                item { ActionRow("Rating", Icons.Default.Star) { model.dialog.value = NativeDialog.Choose("Rating", (0..5).map { value -> (if (value == 0) "Clear rating" else "★".repeat(value)) to { model.launch { model.services.library.rateSong(item.id, value); model.messages.emit("Rating saved") }; Unit } }); dismiss() } }
                item { ActionRow("Go to album", Icons.Default.Album) { item.song?.albumId?.let { model.navigate("album", item.song.album.orEmpty(), it) }; dismiss() } }
                item { ActionRow("Go to artist", Icons.Default.Mic) { item.song?.artistId?.let { model.navigate("artist", item.song.artist.orEmpty(), it) }; dismiss() } }
                if (model.page.value.route == "playlist") {
                    item { ActionRow("Remove from playlist", Icons.Default.RemoveCircleOutline) { val page = model.page.value; val index = item.position ?: page.items.indexOfFirst { it.id == item.id }; model.dialog.value = NativeDialog.Confirm("Remove song?", "Remove ${item.title} from ${page.title}?") { model.launch { model.services.library.updatePlaylist(page.id!!, removeIndices = listOf(index)); model.reload() } }; dismiss() } }
                    if ((item.position ?: 0) > 0) item { ActionRow("Move up", Icons.Default.ArrowUpward) { val page = model.page.value; val songs = page.items.map { it.id }.toMutableList(); val index = item.position!!; songs.add(index - 1, songs.removeAt(index)); model.launch { model.services.library.replacePlaylistSongs(page.id!!, songs); model.reload() }; dismiss() } }
                }
                if (model.page.value.route == "downloads") item { ActionRow("Delete download", Icons.Default.Delete) { model.launch { withContext(Dispatchers.IO) { model.audio?.downloadService()?.deleteCachedAudio(item.id) }; model.reload() }; dismiss() } }
            }
            if (item.kind == "playlist") {
                item { ActionRow("Edit playlist", Icons.Default.Edit) { model.playlistForm(item.id); dismiss() } }
                item { ActionRow("Delete playlist", Icons.Default.Delete) { model.dialog.value = NativeDialog.Confirm("Delete playlist?", "Delete ${item.title} from the server?") { model.launch { model.services.library.deletePlaylist(item.id); if (model.page.value.id == item.id) model.back() else model.reload() } }; dismiss() } }
            }
            if (item.kind == "radio") {
                item { ActionRow("Edit radio station", Icons.Default.Edit) { model.radioForm(item.radio); dismiss() } }
                item { ActionRow("Delete radio station", Icons.Default.Delete) { model.dialog.value = NativeDialog.Confirm("Delete radio station?", item.title) { model.launch { model.services.library.deleteRadio(item.id); model.reload() } }; dismiss() } }
            }
            item { ActionRow("Share", Icons.Default.Share) {
                model.launch {
                    val url = if (item.kind in listOf("song", "album")) {
                        val response = model.services.library.serverRequest("createShare", listOf("id" to item.id))
                        response.optJSONObject("shares")?.optJSONArray("share")?.optJSONObject(0)?.optString("url").orEmpty()
                    } else item.radio?.homePageUrl.orEmpty()
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "${item.title}\n${item.subtitle}\n$url"), "Share"))
                }; dismiss()
            } }
        }
    }
}

@Composable
fun CollectionTools(model: AonsokuViewModel, page: NativePage) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        TextButton({
            val sorts = if (page.route == "artists") listOf("name", "starredAt") else if (page.route == "albums") listOf("name", "artist", "year", "created", "played", "playCount", "random", "starredAt") else listOf("title", "artist", "album", "created", "playedAt", "playCount", "random", "starredAt")
            model.dialog.value = NativeDialog.Choose("Sort by", sorts.map { sort -> sort to { model.filter(sort = sort); Unit } })
        }) { Icon(Icons.AutoMirrored.Filled.Sort, null); Text(L("Sort")) }
        if (page.route == "albums") {
            TextButton({ model.launch { val genres = model.services.library.getGenres(); model.dialog.value = NativeDialog.Choose("Genre", listOf("All genres" to { model.filter(genre = null); Unit }) + genres.map { genre -> genre.value to { model.filter(genre = genre.value); Unit } }) } }) { Text(L("Genre")) }
            TextButton({ model.dialog.value = NativeDialog.Form("Year range", listOf(NativeField("from", "From year", page.fromYear?.toString().orEmpty()), NativeField("to", "To year", page.toYear?.toString().orEmpty()))) { values -> model.filter(fromYear = values["from"]?.toIntOrNull(), toYear = values["to"]?.toIntOrNull()) } }) { Text(L("Year")) }
        }
        if (page.route == "favorites") TextButton({ model.dialog.value = NativeDialog.Choose("Favorites", listOf("songs", "albums", "artists").map { kind -> kind to { model.navigate("favorites-$kind", "Favorite $kind"); Unit } }) }) { Text(L("Type")) }
    }
}

@Composable
fun DownloadStatus(model: AonsokuViewModel, item: LibraryItem) {
    val downloads by model.downloads.collectAsState()
    val status = downloads[item.id]
    if (status != null && status.status != "completed") {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Text("${status.status} ${status.error.orEmpty()}", style = MaterialTheme.typography.labelMedium)
            if (status.status in listOf("queued", "downloading")) {
                if (status.total > 0) LinearProgressIndicator(progress = { status.loaded.toFloat() / status.total }, modifier = Modifier.fillMaxWidth()) else LinearProgressIndicator(Modifier.fillMaxWidth())
                TextButton({ model.audio?.downloadService()?.cancel(item.id) }) { Text(L("Cancel")) }
            } else TextButton({ model.download(item) }) { Text(L("Retry")) }
        }
    }
}
