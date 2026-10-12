package github.realtvop.aonsoku.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.allowHardware
import coil3.request.crossfade
import coil3.toBitmap
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.plugins.audio.QueueSong

enum class CoverKind(val placeholder: ImageVector) {
    Album(Icons.Rounded.Album),
    Song(Icons.Rounded.MusicNote),
    Artist(Icons.Rounded.Person),
    Playlist(Icons.AutoMirrored.Rounded.QueueMusic),
}

/** Cover ids for a song: its own cover and the album cover as fallback. */
@Composable
fun songCoverArt(song: Song): CoverArt {
    val settings = LocalAppGraph.current.settings.state
    val useAlbumCover = settings.value.useAlbumCoverForSongs
    return remember(song.id, song.coverArt, song.albumId, useAlbumCover) {
        songCoverArt(song.coverArt, song.albumId, useAlbumCover)
    }
}

fun songCoverArt(coverArt: String?, albumId: String?, useAlbumCover: Boolean): CoverArt {
    val ordered = if (useAlbumCover) listOf(albumId, coverArt) else listOf(coverArt, albumId)
    return CoverArt(ordered.filterNotNull().filter { it.isNotEmpty() }.distinct())
}

/** Cover of a queue entry, whose cover id already follows the album-cover setting. */
@Composable
fun queueSongCoverArt(song: QueueSong): CoverArt =
    remember(song.id, song.coverArtId, song.albumId) {
        songCoverArt(song.coverArtId, song.albumId, useAlbumCover = false)
    }

/**
 * Artwork from the native image cache with a themed placeholder. Pass
 * [onBitmap] to receive the decoded (software) bitmap, for example to derive
 * an accent color.
 */
@Composable
fun CoverImage(
    art: CoverArt,
    modifier: Modifier = Modifier,
    kind: CoverKind = CoverKind.Album,
    shape: Shape = MaterialTheme.shapes.small,
    contentDescription: String? = null,
    onBitmap: ((android.graphics.Bitmap) -> Unit)? = null,
) {
    var loaded by remember(art) { mutableStateOf(false) }
    Box(
        modifier = modifier
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        contentAlignment = Alignment.Center,
    ) {
        if (!loaded) {
            Icon(
                imageVector = kind.placeholder,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                modifier = Modifier.fillMaxSize(0.42f),
            )
        }
        if (!art.isEmpty) {
            val context = LocalContext.current
            val request = remember(art, onBitmap != null) {
                ImageRequest.Builder(context)
                    .data(art)
                    .crossfade(true)
                    .apply { if (onBitmap != null) allowHardware(false) }
                    .build()
            }
            AsyncImage(
                model = request,
                contentDescription = contentDescription,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                onSuccess = { state ->
                    loaded = true
                    if (onBitmap != null) {
                        runCatching { state.result.image.toBitmap() }.getOrNull()?.let(onBitmap)
                    }
                },
                onError = { loaded = false },
            )
        }
    }
}

/** Square cover that fills the available width. */
@Composable
fun SquareCover(
    art: CoverArt,
    modifier: Modifier = Modifier,
    kind: CoverKind = CoverKind.Album,
    shape: Shape = MaterialTheme.shapes.medium,
    contentDescription: String? = null,
) {
    CoverImage(
        art = art,
        modifier = modifier.fillMaxWidth().aspectRatio(1f),
        kind = kind,
        shape = shape,
        contentDescription = contentDescription,
    )
}
