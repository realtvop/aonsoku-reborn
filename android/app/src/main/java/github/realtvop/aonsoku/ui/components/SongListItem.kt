package github.realtvop.aonsoku.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import github.realtvop.aonsoku.utils.TimeUtils

enum class SongOption {
    PlayNext,
    AddToQueue,
    GoToAlbum,
    GoToArtist,
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SongListItem(
    song: SongEntity,
    modifier: Modifier = Modifier,
    trackNumber: Int? = null,
    showCover: Boolean = true,
    isCurrentSong: Boolean = false,
    isPlaying: Boolean = false,
    onSongClick: () -> Unit,
    onToggleFavorite: (() -> Unit)? = null,
    onOptionSelected: ((SongOption) -> Unit)? = null,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val isStarred = song.starred != null || (song.starredAt ?: 0L) > 0L

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .combinedClickable(
                onClick = onSongClick,
                onLongClick = {
                    if (onOptionSelected != null) {
                        menuExpanded = true
                    }
                }
            )
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showCover) {
            AsyncCoverImage(
                coverArtId = song.coverArt ?: song.albumId,
                type = CoverType.Song,
                sizePx = 150,
                modifier = Modifier.size(48.dp),
                shape = RoundedCornerShape(8.dp),
            )
            Spacer(modifier = Modifier.width(12.dp))
        } else if (trackNumber != null) {
            Box(
                modifier = Modifier.size(36.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (isCurrentSong) {
                    Icon(
                        imageVector = Icons.Default.PlayArrow,
                        contentDescription = "Playing",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(20.dp),
                    )
                } else {
                    Text(
                        text = trackNumber.toString(),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(modifier = Modifier.width(8.dp))
        }

        Column(
            modifier = Modifier.weight(1f),
        ) {
            Text(
                text = song.title,
                style = MaterialTheme.typography.bodyLarge.copy(
                    fontWeight = if (isCurrentSong) FontWeight.Bold else FontWeight.Medium,
                    fontSize = 15.sp,
                ),
                color = if (isCurrentSong) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val subtitle = listOfNotNull(song.artist, song.album).joinToString(" • ")
            if (subtitle.isNotEmpty()) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Spacer(modifier = Modifier.width(8.dp))

        Text(
            text = TimeUtils.formatDuration(song.duration),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (onToggleFavorite != null) {
            IconButton(
                onClick = onToggleFavorite,
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    imageVector = if (isStarred) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                    contentDescription = if (isStarred) "Unfavorite" else "Favorite",
                    tint = if (isStarred) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        if (onOptionSelected != null) {
            Box {
                IconButton(
                    onClick = { menuExpanded = true },
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.MoreVert,
                        contentDescription = "Song options",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
                DropdownMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { menuExpanded = false },
                ) {
                    DropdownMenuItem(
                        text = { Text("Play Next") },
                        onClick = {
                            menuExpanded = false
                            onOptionSelected(SongOption.PlayNext)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Add to Queue") },
                        onClick = {
                            menuExpanded = false
                            onOptionSelected(SongOption.AddToQueue)
                        },
                    )
                    if (song.albumId != null) {
                        DropdownMenuItem(
                            text = { Text("Go to Album") },
                            onClick = {
                                menuExpanded = false
                                onOptionSelected(SongOption.GoToAlbum)
                            },
                        )
                    }
                    if (song.artistId != null) {
                        DropdownMenuItem(
                            text = { Text("Go to Artist") },
                            onClick = {
                                menuExpanded = false
                                onOptionSelected(SongOption.GoToArtist)
                            },
                        )
                    }
                }
            }
        }
    }
}
