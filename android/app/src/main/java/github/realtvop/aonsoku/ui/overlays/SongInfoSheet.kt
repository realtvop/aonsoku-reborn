package github.realtvop.aonsoku.ui.overlays

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.data.parseIsoTimestamp
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.formatBytes
import github.realtvop.aonsoku.ui.components.formatClock
import github.realtvop.aonsoku.ui.components.rememberExpandedSheetState
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.AlbumsRoute
import github.realtvop.aonsoku.ui.navigation.ArtistRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import kotlinx.coroutines.launch

private const val MAX_RECORD_LABELS = 2

private data class SongDetails(val song: Song?, val album: Album?)

/** Technical and library details of one song ("Get info"). */
@Composable
fun SongInfoSheet(overlay: Overlay.SongInfo, controller: OverlayController) {
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val sheetState = rememberExpandedSheetState()
    val scope = rememberCoroutineScope()
    val details by produceState<SongDetails?>(initialValue = null, overlay.songId) {
        val song = runCatching { graph.library.song(overlay.songId) }.getOrNull()
        val album = song?.albumId?.takeIf { it.isNotEmpty() }?.let { albumId ->
            runCatching { graph.library.albumDetails(albumId) }.getOrNull()
        }
        value = SongDetails(song, album)
    }

    fun go(route: Any) {
        scope.launch { sheetState.hide() }.invokeOnCompletion {
            controller.dismiss()
            navigator.open(route)
        }
    }

    ModalBottomSheet(onDismissRequest = controller::dismiss, sheetState = sheetState) {
        Text(
            text = t("songInfo.title"),
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 12.dp),
        )
        val loaded = details
        val song = loaded?.song
        when {
            loaded == null -> Box(
                modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp),
                contentAlignment = Alignment.Center,
            ) { LoadingIndicator() }
            song == null -> Box(
                modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp).padding(24.dp),
                contentAlignment = Alignment.Center,
            ) { Text(t("songInfo.error"), style = MaterialTheme.typography.bodyMedium) }
            else -> SongInfoRows(song = song, album = loaded.album, onNavigate = ::go)
        }
    }
}

@Composable
private fun SongInfoRows(song: Song, album: Album?, onNavigate: (Any) -> Unit) {
    val strings = LocalStrings.current
    val rows = mutableListOf<@Composable () -> Unit>()
    fun row(key: String, content: @Composable () -> Unit) {
        rows += { InfoRow(t("table.columns.$key"), content) }
    }

    row("path") {
        Text(
            text = song.path.orEmpty(),
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier
                .background(
                    MaterialTheme.colorScheme.surfaceContainerHighest,
                    MaterialTheme.shapes.extraSmall,
                )
                .padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
    row("title") { Value(song.title) }
    row("album") {
        LinkValue(song.album.orEmpty(), enabled = !song.albumId.isNullOrEmpty()) {
            onNavigate(AlbumRoute(song.albumId.orEmpty()))
        }
    }
    song.albumArtists?.takeIf { it.isNotEmpty() }?.let { artists ->
        row("albumArtist") {
            FlowRow {
                artists.forEachIndexed { index, artist ->
                    LinkValue(artist.name, enabled = artist.id.isNotEmpty()) {
                        onNavigate(ArtistRoute(artist.id))
                    }
                    if (index < artists.lastIndex) Value(" • ")
                }
            }
        }
    }
    val artists = song.artists?.takeIf { it.isNotEmpty() }
    row("artist") {
        if (artists != null) {
            FlowRow {
                artists.forEachIndexed { index, artist ->
                    LinkValue(artist.name, enabled = artist.id.isNotEmpty()) {
                        onNavigate(ArtistRoute(artist.id))
                    }
                    if (index < artists.lastIndex) Value(" • ")
                }
            }
        } else {
            LinkValue(song.artist.orEmpty(), enabled = !song.artistId.isNullOrEmpty()) {
                onNavigate(ArtistRoute(song.artistId.orEmpty()))
            }
        }
    }
    song.contributors?.takeIf { it.size > 1 }?.let { contributors ->
        row("contributors") {
            Column {
                contributors.forEach { contributor ->
                    val role = contributor.role.replaceFirstChar(Char::titlecase)
                    Value("$role: ${contributor.artist.name}")
                }
            }
        }
    }
    row("year") { Value(song.year?.toString().orEmpty()) }
    row("discNumber") { Value((song.discNumber ?: 1).toString()) }
    row("track") { Value(song.track?.toString().orEmpty()) }
    album?.recordLabels?.takeIf { it.isNotEmpty() }?.let { labels ->
        row("recordLabel") {
            Column { labels.take(MAX_RECORD_LABELS).forEach { Value(it.name) } }
        }
    }
    val genres = buildList {
        song.genre?.takeIf { it.isNotEmpty() }?.let(::add)
        song.genres.orEmpty().forEach { if (it.name.isNotEmpty() && it.name !in this) add(it.name) }
    }
    if (genres.isNotEmpty()) {
        row("genres") {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                genres.forEach { genre ->
                    SuggestionChip(
                        onClick = { onNavigate(AlbumsRoute(filter = "byGenre", genre = genre)) },
                        label = { Text(genre) },
                    )
                }
            }
        }
    }
    row("duration") { Value(formatClock(song.duration)) }
    row("size") { Value(formatBytes(song.size ?: 0)) }
    row("bpm") { Value((song.bpm ?: 0).toString()) }
    row("bitrate") { Value("${song.bitRate ?: 0} kbps") }
    row("codec") { Value(song.suffix.orEmpty().uppercase()) }
    row("plays") { Value((song.playCount ?: 0).toString()) }
    row("lastPlayed") {
        val played = parseIsoTimestamp(song.played)
        if (played != null) {
            Value(t("table.lastPlayed", "date" to strings.fromNow(played, withoutSuffix = true)))
        } else {
            Mark(false)
        }
    }
    row("favorite") { Mark(song.isStarred) }
    song.replayGain?.let { gain ->
        row("trackGain") { Value("${gain.trackGain ?: 0.0} dB") }
        row("trackPeak") { Value((gain.trackPeak ?: 1.0).toString()) }
        row("albumGain") { Value("${gain.albumGain ?: 0.0} dB") }
        row("albumPeak") { Value((gain.albumPeak ?: 1.0).toString()) }
    }
    song.channelCount?.let { channels -> row("channelCount") { Value(channels.toString()) } }
    song.samplingRate?.let { rate -> row("samplingRate") { Value("${rate / 1000.0} kHz") } }
    row("bitDepth") { Value((song.bitDepth ?: 0).toString()) }

    SelectionContainer {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 16.dp),
        ) {
            rows.forEachIndexed { index, content ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(
                            if (index % 2 == 0) {
                                MaterialTheme.colorScheme.surfaceContainerHigh
                            } else {
                                Color.Transparent
                            },
                        ),
                ) { content() }
            }
        }
    }
}

@Composable
private fun InfoRow(label: String, content: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 40.dp)
            .padding(horizontal = 24.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(0.36f).padding(end = 12.dp),
        )
        Box(modifier = Modifier.weight(0.64f)) { content() }
    }
}

@Composable
private fun Value(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun LinkValue(text: String, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = if (enabled) Modifier.clickable(onClick = onClick) else Modifier,
    )
}

@Composable
private fun Mark(positive: Boolean) {
    Icon(
        imageVector = if (positive) Icons.Rounded.Check else Icons.Rounded.Close,
        contentDescription = null,
        modifier = Modifier.size(18.dp),
        tint = if (positive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
    )
}
