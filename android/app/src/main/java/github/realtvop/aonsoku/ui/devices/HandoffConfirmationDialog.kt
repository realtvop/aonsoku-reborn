package github.realtvop.aonsoku.ui.devices

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.data.coordination.DevicePlaybackModel
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.formatClock
import github.realtvop.aonsoku.ui.components.queueSongCoverArt
import github.realtvop.aonsoku.ui.components.songCoverArt

/**
 * Asks before the playback of [target] replaces what plays here
 * (`handoff-confirmation-dialog.tsx`).
 */
@Composable
fun HandoffConfirmationDialog(
    local: PlayerState,
    target: DevicePlaybackModel,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val lookup by rememberSongLookup(target.snapshot?.songId)
    val targetSong = (lookup as? SongLookup.Found)?.song
    val localSong = local.current?.takeIf { !local.isRadio }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(t("settings.crossDevice.playback.continueConfirmTitle")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(t("settings.crossDevice.playback.continueConfirmDesc"))
                PlaybackRow(
                    label = t("settings.crossDevice.playback.currentLocal"),
                    title = local.radio?.name ?: localSong?.title ?: t("player.noSongPlaying"),
                    subtitle = if (local.isRadio) t("radios.label") else localSong?.artist.orEmpty(),
                    art = if (localSong != null) queueSongCoverArt(localSong) else CoverArt(emptyList()),
                    highlighted = false,
                )
                Icon(
                    Icons.Rounded.ArrowDownward,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .size(18.dp),
                )
                PlaybackRow(
                    label = t("settings.crossDevice.playback.willContinue", "name" to target.device.name),
                    title = lookup.title(),
                    subtitle = targetSong?.artistLabel.orEmpty(),
                    art = if (targetSong != null) songCoverArt(targetSong) else CoverArt(emptyList()),
                    highlighted = true,
                    position = target.progressSeconds.takeIf { it > 0 }?.let { formatClock(it.toInt()) },
                )
            }
        },
        confirmButton = {
            Button(onClick = onConfirm) { Text(t("settings.crossDevice.playback.relay")) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(t("generic.cancel")) }
        },
    )
}

@Composable
private fun PlaybackRow(
    label: String,
    title: String,
    subtitle: String,
    art: CoverArt,
    highlighted: Boolean,
    position: String? = null,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = if (highlighted) colors.secondaryContainer else colors.surfaceContainerHighest,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            CoverImage(art = art, kind = CoverKind.Song, modifier = Modifier.size(40.dp))
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = label,
                    style = MaterialTheme.typography.labelSmall,
                    color = if (highlighted) colors.primary else colors.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (subtitle.isNotEmpty() || position != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (position != null) {
                            Text(
                                text = position,
                                style = MaterialTheme.typography.labelMedium,
                                color = if (highlighted) colors.primary else Color.Unspecified,
                            )
                        }
                    }
                }
            }
        }
    }
}
