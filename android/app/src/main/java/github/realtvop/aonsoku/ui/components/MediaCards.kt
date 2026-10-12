package github.realtvop.aonsoku.ui.components

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.Artist

/** Width of a card in a horizontally scrolling section. */
val PreviewCardWidth = 132.dp

/** Square artwork with a title and a secondary line, as used in grids and rows. */
@Composable
fun MediaCard(
    art: CoverArt,
    title: String,
    subtitle: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: CoverKind = CoverKind.Album,
    centered: Boolean = false,
    onLongClick: (() -> Unit)? = null,
) {
    val haptics = LocalHapticFeedback.current
    Column(
        modifier = modifier
            .clip(MaterialTheme.shapes.medium)
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick?.let { action ->
                    {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        action()
                    }
                },
            ),
        horizontalAlignment = if (centered) Alignment.CenterHorizontally else Alignment.Start,
    ) {
        SquareCover(
            art = art,
            kind = kind,
            shape = if (kind == CoverKind.Artist) CircleShape else MaterialTheme.shapes.medium,
            contentDescription = title,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.labelLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = if (centered) TextAlign.Center else TextAlign.Start,
            modifier = Modifier.padding(horizontal = 2.dp),
        )
        if (!subtitle.isNullOrEmpty()) {
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = if (centered) TextAlign.Center else TextAlign.Start,
                modifier = Modifier.padding(horizontal = 2.dp),
            )
        }
        Spacer(Modifier.height(4.dp))
    }
}

@Composable
fun AlbumCard(
    album: Album,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
) {
    MediaCard(
        art = CoverArt(album.coverArt ?: album.id),
        title = album.name,
        subtitle = album.artistLabel,
        onClick = onClick,
        modifier = modifier,
        onLongClick = onLongClick,
    )
}

/** Title row of a home/detail section with an optional "see more" action. */
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    moreLabel: String? = null,
    onMore: (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 8.dp, top = 20.dp, bottom = 4.dp)
            .height(48.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (moreLabel != null && onMore != null) {
            TextButton(onClick = onMore) {
                Text(
                    text = moreLabel,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** Horizontally scrolling album section ("preview list" of the web app). */
@Composable
fun AlbumRowSection(
    title: String,
    albums: List<Album>,
    onAlbum: (Album) -> Unit,
    modifier: Modifier = Modifier,
    onAlbumMenu: ((Album) -> Unit)? = null,
    moreLabel: String? = null,
    onMore: (() -> Unit)? = null,
    cardWidth: Dp = PreviewCardWidth,
) {
    // Lazy keys must be unique, whatever the server returned.
    val unique = remember(albums) { albums.distinctBy { it.id } }
    Column(modifier = modifier.fillMaxWidth()) {
        SectionHeader(title = title, moreLabel = moreLabel, onMore = onMore)
        LazyRow(
            contentPadding = PaddingValues(horizontal = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(unique, key = { it.id }) { album ->
                AlbumCard(
                    album = album,
                    onClick = { onAlbum(album) },
                    modifier = Modifier.width(cardWidth),
                    onLongClick = onAlbumMenu?.let { menu -> { menu(album) } },
                )
            }
        }
    }
}

/** Horizontally scrolling artist section with round artwork. */
@Composable
fun ArtistRowSection(
    title: String,
    artists: List<Artist>,
    onArtist: (Artist) -> Unit,
    modifier: Modifier = Modifier,
) {
    val unique = remember(artists) { artists.distinctBy { it.id } }
    Column(modifier = modifier.fillMaxWidth()) {
        SectionHeader(title = title)
        LazyRow(
            contentPadding = PaddingValues(horizontal = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(unique, key = { it.id }) { artist ->
                MediaCard(
                    art = CoverArt(artist.coverArt ?: artist.id),
                    title = artist.name,
                    subtitle = null,
                    onClick = { onArtist(artist) },
                    modifier = Modifier.width(112.dp),
                    kind = CoverKind.Artist,
                    centered = true,
                )
            }
        }
    }
}
