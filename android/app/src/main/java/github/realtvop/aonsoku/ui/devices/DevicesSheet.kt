package github.realtvop.aonsoku.ui.devices

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SettingsRemote
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.coordination.CoordinationConnection
import github.realtvop.aonsoku.data.coordination.CoordinationManager
import github.realtvop.aonsoku.data.coordination.DevicePlaybackModel
import github.realtvop.aonsoku.data.coordination.HandoffPhase
import github.realtvop.aonsoku.data.coordination.HandoffState
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.queueSongCoverArt
import github.realtvop.aonsoku.ui.components.songCoverArt
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.SettingsRoute
import github.realtvop.aonsoku.ui.overlays.OverlayController
import github.realtvop.aonsoku.ui.settings.SettingsCategory
import kotlinx.coroutines.launch

private val NoArtwork = CoverArt(emptyList())

/**
 * The device panel (`device-panel.tsx`): this device, the devices playing
 * elsewhere, which can be controlled from here or continued here, and the
 * devices that played lately while offline. Opened from the player, the home
 * page, and the mini player.
 */
@Composable
fun DevicesSheet(controller: OverlayController) {
    val graph = LocalAppGraph.current
    val coordination = graph.coordination
    val navigator = LocalNavigator.current
    val scope = rememberCoroutineScope()
    // Half the screen first, like the web's drawer; dragged up, all of it.
    val sheetState = rememberBottomSheetState(initialValue = SheetValue.Hidden)
    val state by coordination.state.collectAsStateWithLifecycle()
    val handoff by coordination.handoff.collectAsStateWithLifecycle()
    val local by graph.player.local.collectAsStateWithLifecycle()
    val groups = rememberDeviceGroups()

    // Opening the panel is a good moment to try the connection again.
    LaunchedEffect(Unit) { coordination.reconnect() }

    fun openSettings() {
        scope.launch { sheetState.hide() }.invokeOnCompletion {
            controller.dismiss()
            navigator.open(SettingsRoute(SettingsCategory.CrossDevice.id))
        }
    }

    ModalBottomSheet(onDismissRequest = controller::dismiss, sheetState = sheetState) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 24.dp, end = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Rounded.Devices, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Text(
                text = t("settings.crossDevice.title"),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = ::openSettings) {
                Icon(Icons.Rounded.Settings, contentDescription = t("settings.label"))
            }
        }
        Text(
            text = t("settings.crossDevice.description"),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 12.dp),
        )
        HorizontalDivider()

        val controlling = state.controlledDeviceId != null
        var offlineExpanded by rememberSaveable { mutableStateOf(true) }
        LazyColumn(
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (state.isRegistered && state.isConnected) {
                item(key = "handoff") { HandoffStatusRow(handoff) }
            }
            groups.thisDevice?.let { model ->
                item(key = "this-label") { SectionLabel(t("settings.crossDevice.playback.thisDevice")) }
                item(key = "this") {
                    LocalDeviceCard(
                        model = model,
                        local = local,
                        active = !controlling,
                        onExitControl = if (controlling) {
                            { coordination.exitRemoteControl() }
                        } else {
                            null
                        },
                    )
                }
            }
            when {
                !state.isRegistered -> item(key = "unconfigured") {
                    Notice(
                        icon = Icons.Rounded.Link,
                        tint = MaterialTheme.colorScheme.primary,
                        title = t("settings.crossDevice.error.unconfiguredTitle"),
                        description = t("settings.crossDevice.error.unconfiguredDescription"),
                    ) {
                        OutlinedButton(onClick = ::openSettings) {
                            Icon(Icons.Rounded.Settings, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(t("settings.crossDevice.connect"))
                        }
                    }
                }
                !state.isConnected -> item(key = "disconnected") {
                    val connecting = state.connection == CoordinationConnection.Connecting ||
                        state.connection == CoordinationConnection.Reconnecting
                    Notice(
                        icon = Icons.Rounded.WifiOff,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        title = t("settings.crossDevice.error.connectFailed"),
                        description = t("settings.crossDevice.error.disconnectedDescription"),
                    ) {
                        OutlinedButton(onClick = coordination::reconnect, enabled = !connecting) {
                            if (connecting) {
                                LoadingIndicator(modifier = Modifier.size(18.dp))
                            } else {
                                Icon(Icons.Rounded.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                            }
                            Spacer(Modifier.width(8.dp))
                            Text(t("settings.crossDevice.retry"))
                        }
                    }
                }
                else -> {
                    if (groups.live.isNotEmpty()) {
                        item(key = "live-label") { SectionLabel(t("settings.crossDevice.playback.liveDevices")) }
                        items(groups.live, key = { "live-${it.device.id}" }) { model ->
                            val active = state.controlledDeviceId == model.device.id
                            RemoteDeviceCard(
                                model = model,
                                active = active,
                                onControl = when {
                                    active -> { { coordination.exitRemoteControl() } }
                                    model.canBeControlled -> { { coordination.enterRemoteControl(model.device.id) } }
                                    else -> null
                                },
                                onContinue = if (model.canBeContinuedLocally) {
                                    { coordination.requestHandoff(model.device.id) }
                                } else {
                                    null
                                },
                                continueLabel = t("settings.crossDevice.playback.relay"),
                            )
                        }
                    }
                    if (groups.offline.isNotEmpty()) {
                        item(key = "offline-label") {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(role = Role.Button) { offlineExpanded = !offlineExpanded }
                                    .padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                SectionLabel(
                                    text = t("settings.crossDevice.playback.offlineSnapshots"),
                                    modifier = Modifier.weight(1f),
                                )
                                Icon(
                                    imageVector = if (offlineExpanded) {
                                        Icons.Rounded.ExpandLess
                                    } else {
                                        Icons.Rounded.ExpandMore
                                    },
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        if (offlineExpanded) {
                            items(groups.offline, key = { "offline-${it.device.id}" }) { model ->
                                RemoteDeviceCard(
                                    model = model,
                                    active = false,
                                    onControl = null,
                                    onContinue = if (model.canBeContinuedLocally) {
                                        { coordination.requestHandoff(model.device.id) }
                                    } else {
                                        null
                                    },
                                    continueLabel = t("settings.crossDevice.playback.continue"),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    val pending = handoff.pendingDeviceId?.let { id -> groups.others.firstOrNull { it.device.id == id } }
    if (pending != null) {
        HandoffConfirmationDialog(
            local = local,
            target = pending,
            onConfirm = coordination::confirmHandoff,
            onDismiss = coordination::dismissHandoff,
        )
    }
}

@Composable
private fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.padding(horizontal = 4.dp),
    )
}

/** What the handoff this device asked for is doing (`handoff-status-row.tsx`). */
@Composable
private fun HandoffStatusRow(handoff: HandoffState) {
    val error = handoff.error
    val phase = handoff.phase
    AnimatedVisibility(visible = error != null || phase != null) {
        val colors = MaterialTheme.colorScheme
        Surface(
            shape = MaterialTheme.shapes.large,
            color = when {
                error != null -> colors.errorContainer
                phase == HandoffPhase.Committed -> colors.primaryContainer
                else -> colors.surfaceContainerHighest
            },
            contentColor = when {
                error != null -> colors.onErrorContainer
                phase == HandoffPhase.Committed -> colors.onPrimaryContainer
                else -> colors.onSurfaceVariant
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                when {
                    error != null -> Icon(Icons.Rounded.ErrorOutline, contentDescription = null)
                    phase == HandoffPhase.Committed -> Icon(Icons.Rounded.CheckCircle, contentDescription = null)
                    else -> LoadingIndicator(modifier = Modifier.size(24.dp))
                }
                Spacer(Modifier.width(12.dp))
                Text(
                    text = error ?: t(
                        if (phase == HandoffPhase.Committed) {
                            "settings.crossDevice.handoff.committed"
                        } else {
                            "settings.crossDevice.handoff.prepare"
                        },
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}

/** This device: what it plays, and the way back from controlling another one. */
@Composable
private fun LocalDeviceCard(
    model: DevicePlaybackModel,
    local: PlayerState,
    active: Boolean,
    onExitControl: (() -> Unit)?,
) {
    val song = local.current?.takeIf { !local.isRadio }
    DeviceCard(
        title = local.radio?.name ?: song?.title ?: t("player.noSongPlaying"),
        art = if (song != null) queueSongCoverArt(song) else NoArtwork,
        deviceName = model.device.name,
        deviceIcon = deviceIcon(CoordinationManager.PLATFORM),
        active = active,
    ) {
        if (onExitControl != null) {
            IconButton(onClick = onExitControl) {
                Icon(Icons.Rounded.SettingsRemote, contentDescription = t("settings.crossDevice.playback.exitControl"))
            }
        }
    }
}

/** Another device and what can be done with its playback. */
@Composable
private fun RemoteDeviceCard(
    model: DevicePlaybackModel,
    active: Boolean,
    onControl: (() -> Unit)?,
    onContinue: (() -> Unit)?,
    continueLabel: String,
) {
    val lookup by rememberSongLookup(model.snapshot?.songId)
    val found = (lookup as? SongLookup.Found)?.song
    DeviceCard(
        title = lookup.title(),
        art = if (found != null) songCoverArt(found) else NoArtwork,
        deviceName = model.device.name,
        deviceIcon = deviceIcon(model.device.platform),
        active = active,
        loading = lookup == SongLookup.Loading,
    ) {
        if (onControl != null) {
            val label = t(
                if (active) {
                    "settings.crossDevice.playback.exitControl"
                } else {
                    "settings.crossDevice.playback.remoteControl"
                },
            )
            if (active) {
                FilledIconToggleButton(checked = true, onCheckedChange = { onControl() }) {
                    Icon(Icons.Rounded.SettingsRemote, contentDescription = label)
                }
            } else {
                IconToggleButton(checked = false, onCheckedChange = { onControl() }) {
                    Icon(Icons.Rounded.SettingsRemote, contentDescription = label)
                }
            }
        }
        if (onContinue != null) {
            IconButton(onClick = onContinue) {
                Icon(Icons.Rounded.SwapHoriz, contentDescription = continueLabel)
            }
        }
    }
}

@Composable
private fun DeviceCard(
    title: String,
    art: CoverArt,
    deviceName: String,
    deviceIcon: ImageVector,
    active: Boolean,
    loading: Boolean = false,
    actions: @Composable () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Surface(
        shape = MaterialTheme.shapes.large,
        color = if (active) colors.secondaryContainer else colors.surfaceContainerHigh,
        border = if (active) BorderStroke(1.dp, colors.primary.copy(alpha = 0.5f)) else null,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(start = 12.dp, end = 4.dp, top = 12.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(contentAlignment = Alignment.Center) {
                CoverImage(art = art, kind = CoverKind.Song, modifier = Modifier.size(48.dp))
                if (loading) LoadingIndicator(modifier = Modifier.size(24.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = deviceIcon,
                        contentDescription = null,
                        tint = colors.onSurfaceVariant,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = deviceName,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            actions()
        }
    }
}

/** A message with an action in place of the device list. */
@Composable
private fun Notice(
    icon: ImageVector,
    tint: Color,
    title: String,
    description: String,
    action: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(text = title, style = MaterialTheme.typography.titleSmall)
        }
        Text(
            text = description,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        action()
    }
}
