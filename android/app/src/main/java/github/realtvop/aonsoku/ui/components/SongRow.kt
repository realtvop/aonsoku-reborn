package github.realtvop.aonsoku.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.i18n.t
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** The song that is loaded in the player, for highlighting list rows. */
@Immutable
data class NowPlaying(val songId: String? = null, val isPlaying: Boolean = false) {
    fun isCurrent(song: Song): Boolean = songId != null && songId == song.id
}

@Composable
fun rememberNowPlaying(): NowPlaying {
    val player = LocalAppGraph.current.player
    val flow = remember(player) {
        player.state
            .map { NowPlaying(if (it.isRadio) null else it.current?.id, it.isPlaying) }
            .distinctUntilChanged()
    }
    val value by flow.collectAsStateWithLifecycle(NowPlaying())
    return value
}

/**
 * A song in a list: artwork, title and a secondary line, with an optional
 * overflow button. The current song is marked on its artwork.
 */
@Composable
fun SongRow(
    song: Song,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    nowPlaying: NowPlaying = NowPlaying(),
    subtitle: String = song.artistLabel,
    coverSize: Dp = 48.dp,
    onMore: (() -> Unit)? = null,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    val isCurrent = nowPlaying.isCurrent(song)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .defaultMinSize(minHeight = 60.dp)
            .padding(start = 16.dp, end = if (onMore != null) 4.dp else 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(modifier = Modifier.size(coverSize)) {
            CoverImage(
                art = songCoverArt(song),
                modifier = Modifier.size(coverSize),
                kind = CoverKind.Song,
                shape = MaterialTheme.shapes.small,
            )
            if (isCurrent) {
                Box(
                    modifier = Modifier
                        .size(coverSize)
                        .clip(MaterialTheme.shapes.small)
                        .background(Color.Black.copy(alpha = 0.55f)),
                    contentAlignment = Alignment.Center,
                ) {
                    NowPlayingBars(
                        animate = nowPlaying.isPlaying,
                        color = Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f).padding(vertical = 8.dp)) {
            Text(
                text = song.title,
                style = MaterialTheme.typography.bodyLarge,
                color = if (isCurrent) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
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
        CachedIndicator(songId = song.id, modifier = Modifier.padding(start = 8.dp))
        trailing()
        if (onMore != null) {
            IconButton(onClick = onMore) {
                Icon(
                    Icons.Rounded.MoreVert,
                    contentDescription = t("playlist.buttons.options", "name" to song.title),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

/** "Disc N" divider shown between the discs of a multi-disc album. */
@Composable
fun DiscHeader(number: Int, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(modifier = Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            Icon(
                Icons.Rounded.Album,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Text(
            text = t("album.table.discNumber", "number" to number),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Three equalizer bars that move while [animate] is true. */
@Composable
fun NowPlayingBars(
    animate: Boolean,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.primary,
) {
    val phase = if (animate) {
        val transition = rememberInfiniteTransition(label = "nowPlayingBars")
        val value by transition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 900, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = "nowPlayingBarsPhase",
        )
        value
    } else {
        0.15f
    }
    Canvas(modifier = modifier) {
        val bars = 3
        val gap = size.width * 0.14f
        val barWidth = (size.width - gap * (bars - 1)) / bars
        for (index in 0 until bars) {
            val shifted = (phase + index * 0.33f) % 1f
            // Triangle wave between 0.3 and 1.
            val level = 0.3f + 0.7f * (1f - kotlin.math.abs(shifted * 2f - 1f))
            val barHeight = size.height * level
            drawRoundRect(
                color = color,
                topLeft = Offset(index * (barWidth + gap), size.height - barHeight),
                size = Size(barWidth, barHeight),
                cornerRadius = CornerRadius(barWidth / 2f, barWidth / 2f),
            )
        }
    }
}
