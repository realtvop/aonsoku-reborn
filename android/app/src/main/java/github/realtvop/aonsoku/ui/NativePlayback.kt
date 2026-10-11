@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package github.realtvop.aonsoku.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import github.realtvop.aonsoku.plugins.audio.*
import github.realtvop.aonsoku.plugins.lyrics.LyricsTrack

@Composable
fun NativePlayer(model: AonsokuViewModel, close: () -> Unit) {
    val queue by model.queue.collectAsState()
    val playback by model.playback.collectAsState()
    val libraryRevision by model.libraryRevision.collectAsState()
    val preferences by model.preferences.collectAsState()
    val song by produceState<github.realtvop.aonsoku.plugins.data.db.entity.SongEntity?>(null, queue.currentSong?.id, libraryRevision) { value = queue.currentSong?.id?.let { model.services.library.getSong(it) ?: model.audio?.downloadService()?.cachedSong(it) } }
    var tab by remember { mutableIntStateOf(0) }
    Dialog(close, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.safeDrawingPadding()) {
                TopAppBar(title = { Text(L("Now playing")) }, navigationIcon = { IconButton(close) { Icon(Icons.Default.KeyboardArrowDown, L("Close")) } }, actions = {
                    IconButton({ model.navigate("settings/cross-device", "Cross-device"); close() }) { Icon(Icons.Default.Devices, L("Devices")) }
                    IconButton({ model.dialog.value = NativeDialog.Choose("Sleep timer", listOf(15, 30, 45, 60, 90).map { minutes -> "$minutes minutes" to { model.command(AudioCommand.SetSleepTimer(minutes * 60.0, "duration")); Unit } } + listOf("At end of song" to { model.command(AudioCommand.SetSleepTimer(1.0, "endOfTrack")); Unit }, "Cancel timer" to { model.command(AudioCommand.CancelSleepTimer); Unit })) }) { Icon(Icons.Default.Bedtime, L("Sleep timer")) }
                })
                PrimaryTabRow(tab) { listOf("Playing", "Queue", "Lyrics").forEachIndexed { index, label -> Tab(tab == index, { tab = index }, text = { Text(L(label)) }) } }
                when (tab) {
                    0 -> LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        item { Cover(model, if (model.booleanPreference("player_store.settings.coverArt.useAlbumCoverForSongs", false)) queue.currentSong?.albumId ?: queue.currentSong?.coverArtId else queue.currentSong?.coverArtId, Modifier.widthIn(max = 440.dp).fillMaxWidth().aspectRatio(1f)) }
                        item { Text(queue.currentSong?.title.orEmpty(), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold); Text(queue.currentSong?.artist.orEmpty(), Modifier.clickable { song?.artistId?.let { model.navigate("artist", song?.artist.orEmpty(), it); close() } }, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        item {
                            var scrub by remember { mutableStateOf<Float?>(null) }
                            Slider((scrub ?: playback.currentTimeSeconds.toFloat()).coerceIn(0f, playback.durationSeconds.toFloat().coerceAtLeast(1f)), { scrub = it }, onValueChangeFinished = { scrub?.let { model.command(AudioCommand.Seek(it.toDouble())) }; scrub = null }, valueRange = 0f..playback.durationSeconds.toFloat().coerceAtLeast(1f), enabled = playback.durationSeconds > 0)
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text(formatTime((scrub ?: playback.currentTimeSeconds.toFloat()).toDouble())); Text(if (playback.durationSeconds > 0) formatTime(playback.durationSeconds) else L("Live")) }
                            if (playback.isBuffering) LinearProgressIndicator(Modifier.fillMaxWidth())
                        }
                        item {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                IconButton({ model.command(AudioCommand.SetShuffle(!queue.isShuffleActive)) }) { Icon(Icons.Default.Shuffle, L("Shuffle"), tint = if (queue.isShuffleActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface) }
                                IconButton({ model.command(AudioCommand.Previous) }) { Icon(Icons.Default.SkipPrevious, L("Previous")) }
                                FilledIconButton({ model.command(AudioCommand.TogglePlayPause) }, Modifier.size(72.dp)) { Icon(if (playback.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, L("Play or pause"), Modifier.size(36.dp)) }
                                IconButton({ model.command(AudioCommand.Next) }) { Icon(Icons.Default.SkipNext, L("Next")) }
                                IconButton({ model.command(AudioCommand.SetRepeat(when (queue.repeatMode) { "off" -> "all"; "all" -> "one"; else -> "off" })) }) { Icon(if (queue.repeatMode == "one") Icons.Default.RepeatOne else Icons.Default.Repeat, "Repeat ${queue.repeatMode}", tint = if (queue.repeatMode != "off") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface) }
                            }
                        }
                        item { Row { IconButton({ song?.let { model.favorite(it.item()) } }, enabled = song != null) { Icon(if (song?.starred != null) Icons.Default.Favorite else Icons.Default.FavoriteBorder, L("Favorite")) }; IconButton({ song?.let { model.addToPlaylist(listOf(it.id)) } }, enabled = song != null) { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, L("Add to playlist")) }; IconButton({ song?.let { model.download(it.item()) } }, enabled = song != null) { Icon(Icons.Default.Download, L("Download")) } } }
                        item { var volume by remember(playback.volume) { mutableFloatStateOf(playback.volume.toFloat()) }; Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.AutoMirrored.Filled.VolumeUp, L("Volume")); Slider(volume.coerceIn(0f, 1f), { volume = it }, onValueChangeFinished = { model.command(AudioCommand.SetVolume(volume.toDouble())) }) } }
                        item { val remaining = model.audio?.getSleepTimerRemaining() ?: 0.0; if (remaining > 0) Text("${L("Sleep timer")}: ${formatTime(remaining)}") }
                    }
                    1 -> LazyColumn(Modifier.weight(1f)) {
                        item { Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) { Text(L("Added by you"), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge); TextButton({ model.command(AudioCommand.ClearUserQueue) }) { Text(L("Clear")) } } }
                        itemsIndexed(queue.userQueue, key = { index, song -> "user:$index:${song.id}" }) { index, song -> QueueRow(model, song, { model.command(AudioCommand.PlayUserQueueAtIndex(index)) }, { model.command(AudioCommand.RemoveFromUserQueue(listOf(index))) }, if (index > (if (queue.isInUserQueue) 1 else 0)) { { model.command(AudioCommand.ReorderUserQueue(index, index - 1)) } } else null) }
                        item { Text(queue.sourceName ?: L("Context queue"), Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge) }
                        itemsIndexed(queue.contextSongs, key = { index, song -> "context:$index:${song.id}" }) { index, song -> QueueRow(model, song, { model.command(AudioCommand.PlayAtIndex(index, null)) }, { val songs = queue.contextSongs.toMutableList().apply { removeAt(index) }; model.command(AudioCommand.UpdateContextQueue(songs, (queue.currentIndex - if (index < queue.currentIndex) 1 else 0).coerceIn(0, (songs.size - 1).coerceAtLeast(0)))) }, if (index > 0) { { model.command(AudioCommand.ReorderContextQueue(index, index - 1)) } } else null) }
                    }
                    2 -> {
                        val revision by model.lyricsRevision.collectAsState()
                        val track by produceState(LyricsTrack(), song?.id, revision, preferences["native.lyrics.disabled.${song?.id}"], model.preference("player_store.settings.lyrics"), model.preference("player_store.settings.privacy")) { value = song?.let { model.lyricsService.load(it) } ?: LyricsTrack() }
                        val list = rememberLazyListState()
                        val lines = remember(track) { track.lines }
                        val offset = model.preference("native.lyrics.offset.${song?.id}")?.toDoubleOrNull()?.div(1000) ?: 0.0
                        val active = lines.indexOfLast { it.seconds != null && it.seconds!! <= playback.currentTimeSeconds + offset }
                        LaunchedEffect(active) { if (active >= 0 && !list.isScrollInProgress) list.animateScrollToItem(active, -180) }
                        Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) { Text(track.source, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium); TextButton({ song?.let(model::lyricsOptions) }) { Text(L("Options")) } }
                        if (lines.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(L("No lyrics found")) }
                        LazyColumn(state = list, modifier = Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 24.dp, vertical = 36.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                            itemsIndexed(lines) { index, line ->
                                track.romaji?.let { roman -> github.realtvop.aonsoku.plugins.lyrics.LyricsParser.parse(roman).firstOrNull { it.seconds == line.seconds }?.let { Text(it.text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
                                if (model.booleanPreference("player_store.settings.lyrics.showTranslation", true) || index == 0 || lines[index - 1].seconds != line.seconds) Text(line.text, style = MaterialTheme.typography.headlineSmall, fontWeight = if ((active >= 0 && line.seconds == lines[active].seconds)) FontWeight.Bold else FontWeight.Normal, color = if (!track.synced || (active >= 0 && line.seconds == lines[active].seconds)) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxWidth().clickable(enabled = line.seconds != null) { model.command(AudioCommand.Seek((line.seconds!! - offset).coerceAtLeast(0.0))) })
                            }

                        }
                    }
                }
            }
            NativeDialogs(model)
        }
    }
}
@Composable
private fun QueueRow(model: AonsokuViewModel, song: QueueSong, play: () -> Unit, remove: () -> Unit, up: (() -> Unit)?) {
    ListItem(headlineContent = { Text(song.title, maxLines = 1) }, supportingContent = { Text(song.artist, maxLines = 1) }, leadingContent = { Cover(model, song.coverArtId, Modifier.size(48.dp)) }, trailingContent = { Row { if (up != null) IconButton(up) { Icon(Icons.Default.ArrowUpward, L("Move up")) }; IconButton(remove) { Icon(Icons.Default.Close, L("Remove")) } } }, modifier = Modifier.clickable(onClick = play))
}
