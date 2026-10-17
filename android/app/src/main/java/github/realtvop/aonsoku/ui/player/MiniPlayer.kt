package github.realtvop.aonsoku.ui.player

import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerController
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.queueSongCoverArt
import github.realtvop.aonsoku.ui.shell.MiniPlayerHeight

/**
 * Floating compact player: artwork, title and artist, play/pause and next.
 * Tapping it opens the full-screen player.
 */
@Composable
fun MiniPlayer(
    state: PlayerState,
    onExpand: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val player = LocalAppGraph.current.player
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .height(MiniPlayerHeight),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 3.dp,
        shadowElevation = 8.dp,
    ) {
        Box(modifier = Modifier.clickable(onClick = onExpand)) {
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(start = 10.dp, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MiniArtwork(state)
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = state.radio?.name ?: state.current?.title.orEmpty(),
                        style = MaterialTheme.typography.labelLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val remote = state.remoteDevice
                    if (remote != null) {
                        // Where the song plays, in place of its artist.
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                Icons.Rounded.Devices,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(14.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = t("settings.crossDevice.playback.controllingDevice", "name" to remote),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.primary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    } else {
                        Text(
                            text = if (state.isRadio) {
                                t("radios.label")
                            } else {
                                state.current?.artist.orEmpty()
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                IconButton(onClick = player::togglePlayPause) {
                    when {
                        state.isLoading -> LoadingIndicator(modifier = Modifier.size(28.dp))
                        state.isPlaying -> Icon(
                            Icons.Rounded.Pause,
                            contentDescription = t("player.tooltips.pause"),
                            modifier = Modifier.size(28.dp),
                        )
                        else -> Icon(
                            Icons.Rounded.PlayArrow,
                            contentDescription = t("player.tooltips.play"),
                            modifier = Modifier.size(28.dp),
                        )
                    }
                }
                IconButton(onClick = player::next, enabled = state.hasNext) {
                    Icon(
                        Icons.Rounded.SkipNext,
                        contentDescription = t("player.tooltips.next"),
                        modifier = Modifier.size(26.dp),
                    )
                }
            }
            if (!state.isRadio) {
                MiniProgress(player, modifier = Modifier.align(Alignment.BottomCenter))
            }
        }
    }
}

@Composable
private fun MiniArtwork(state: PlayerState) {
    val song = state.current
    if (state.isRadio || song == null) {
        Surface(
            modifier = Modifier.size(44.dp),
            shape = MaterialTheme.shapes.small,
            color = MaterialTheme.colorScheme.surfaceContainerHighest,
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Rounded.Radio,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        return
    }
    CoverImage(
        art = queueSongCoverArt(song),
        modifier = Modifier.size(44.dp),
        kind = CoverKind.Song,
        shape = MaterialTheme.shapes.small,
    )
}

@Composable
private fun MiniProgress(player: PlayerController, modifier: Modifier = Modifier) {
    val progress by player.progress.collectAsStateWithLifecycle()
    val fraction = if (progress.duration > 0) {
        (progress.position / progress.duration).toFloat().coerceIn(0f, 1f)
    } else {
        0f
    }
    LinearProgressIndicator(
        progress = { fraction },
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .height(2.dp),
        trackColor = Color.Transparent,
        gapSize = 0.dp,
        drawStopIndicator = {},
    )
}
