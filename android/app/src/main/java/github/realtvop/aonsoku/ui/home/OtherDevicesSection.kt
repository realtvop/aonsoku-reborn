package github.realtvop.aonsoku.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.data.coordination.DevicePlaybackModel
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.parseIsoTimestamp
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.songCoverArt
import github.realtvop.aonsoku.ui.devices.SongLookup
import github.realtvop.aonsoku.ui.devices.deviceIcon
import github.realtvop.aonsoku.ui.devices.rememberDeviceGroups
import github.realtvop.aonsoku.ui.devices.rememberSongLookup
import github.realtvop.aonsoku.ui.devices.title

/**
 * The other devices that play, or played lately while offline, at the top of
 * the home page (`home-overview.tsx`). Every part of it opens the devices.
 */
@Composable
fun OtherDevicesSection(onOpen: () -> Unit) {
    val devices = rememberDeviceGroups().others
    if (devices.isEmpty()) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(top = 4.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier.padding(start = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Rounded.Devices,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = t("settings.crossDevice.playback.otherDevices"),
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onOpen) {
                Text(t("settings.crossDevice.playback.showDevices"))
                Spacer(Modifier.width(4.dp))
                Icon(
                    Icons.AutoMirrored.Rounded.ArrowForward,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        devices.forEach { model -> OverviewCard(model, onClick = onOpen) }
    }
}

@Composable
private fun OverviewCard(model: DevicePlaybackModel, onClick: () -> Unit) {
    val strings = LocalStrings.current
    val lookup by rememberSongLookup(model.snapshot?.songId)
    val song = (lookup as? SongLookup.Found)?.song
    val lastSeen = model.device.lastOnlineAt?.let(::parseIsoTimestamp)?.let { strings.fromNow(it) }
    val colors = MaterialTheme.colorScheme
    Surface(
        onClick = onClick,
        shape = MaterialTheme.shapes.large,
        color = colors.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(start = 12.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CoverImage(
                art = if (song != null) songCoverArt(song) else CoverArt(emptyList()),
                kind = CoverKind.Song,
                modifier = Modifier.size(40.dp),
            )
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = lookup.title(),
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        deviceIcon(model.device.platform),
                        contentDescription = null,
                        tint = colors.onSurfaceVariant,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = model.device.name,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    Text(
                        text = " · " + if (model.isOnline) {
                            t("settings.crossDevice.connectionState.connected")
                        } else {
                            lastSeen ?: t("settings.crossDevice.never")
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (model.isOnline) colors.primary else colors.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
            }
            Icon(
                Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.onSurfaceVariant,
            )
        }
    }
}
