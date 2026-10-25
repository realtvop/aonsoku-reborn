package github.realtvop.aonsoku.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.coordination.CoordinationApiException
import github.realtvop.aonsoku.data.coordination.CoordinationConnection
import github.realtvop.aonsoku.data.coordination.DeviceDto
import github.realtvop.aonsoku.data.parseIsoTimestamp
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.theme.StatusColors
import github.realtvop.aonsoku.ui.devices.deviceIcon
import github.realtvop.aonsoku.ui.overlays.ConfirmDialog
import kotlinx.coroutines.launch

/**
 * Registering this device on a coordination server, the devices of the
 * account, and leaving it again (`settings/pages/cross-device`).
 */
@Composable
fun CrossDeviceSettings() {
    val graph = LocalAppGraph.current
    val coordination = graph.coordination
    val strings = LocalStrings.current
    val scope = rememberCoroutineScope()
    val state by coordination.state.collectAsStateWithLifecycle()
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val signedInUrl = graph.session.credentials?.serverUrl.orEmpty()

    var serverUrl by rememberSaveable(state.serverUrl) { mutableStateOf(state.serverUrl) }
    var identityUrl by rememberSaveable(state.identityUrl) {
        mutableStateOf(state.identityUrl.ifEmpty { settings.server.primaryUrl.ifEmpty { signedInUrl } })
    }
    var deviceName by rememberSaveable { mutableStateOf(coordination.defaultDeviceName()) }
    var connecting by remember { mutableStateOf(false) }
    var confirmDisconnect by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var revoking by remember { mutableStateOf<DeviceDto?>(null) }
    var renaming by remember { mutableStateOf<DeviceDto?>(null) }

    val missingFields = t("settings.crossDevice.error.missingFields")
    val connectFailed = t("settings.crossDevice.error.connectFailed")
    val connected = t("settings.crossDevice.connected")

    fun connect() {
        if (serverUrl.isBlank() || identityUrl.isBlank() || graph.session.credentials == null) {
            graph.toaster.error(missingFields)
            return
        }
        connecting = true
        scope.launch {
            runSuspendCatching {
                coordination.connect(serverUrl, identityUrl, deviceName.ifBlank { coordination.defaultDeviceName() })
            }
                .onSuccess { graph.toaster.success(connected) }
                .onFailure { graph.toaster.error("$connectFailed: ${it.describe()}") }
            connecting = false
        }
    }

    /** Runs a device action and reports how it went. */
    fun act(success: String, action: suspend () -> Unit) {
        scope.launch {
            runSuspendCatching { action() }
                .onSuccess { graph.toaster.success(success) }
                .onFailure { graph.toaster.error(it.describe()) }
        }
    }

    SettingsPage(title = t("settings.crossDevice.title")) {
        settingsSection(key = "status", description = strings.t("settings.crossDevice.description")) {
            item {
                SettingRow(
                    title = t("settings.crossDevice.connectionState.label"),
                    trailing = { ConnectionBadge(state.connection) },
                )
            }
            item {
                SettingRow(
                    title = t("settings.crossDevice.lastSync.label"),
                    trailing = {
                        TrailingValue(
                            state.lastSyncAt?.let { strings.fromNow(it) } ?: t("settings.crossDevice.never"),
                        )
                    },
                )
            }
            item {
                SettingRow(
                    title = t("settings.crossDevice.devices"),
                    trailing = {
                        TrailingValue(t("settings.crossDevice.deviceCount", "count" to state.devices.size))
                    },
                )
            }
        }

        if (!state.isRegistered) {
            settingsSection(
                key = "setup",
                title = strings.t("settings.crossDevice.setup.title"),
                description = strings.t("settings.crossDevice.setup.description"),
            ) {
                item {
                    FieldSetting(
                        title = t("settings.crossDevice.serverUrl.label"),
                        info = t("settings.crossDevice.serverUrl.info"),
                        value = serverUrl,
                        onValueChange = { serverUrl = it },
                        placeholder = "https://coord.example.com",
                        enabled = !connecting,
                    )
                }
                item {
                    FieldSetting(
                        title = t("settings.crossDevice.identityUrl.label"),
                        info = t("settings.crossDevice.identityUrl.info"),
                        value = identityUrl,
                        onValueChange = { identityUrl = it },
                        placeholder = signedInUrl.ifEmpty { "https://navidrome.example" },
                        enabled = !connecting,
                    )
                }
                item {
                    FieldSetting(
                        title = t("settings.crossDevice.deviceName.label"),
                        info = t("settings.crossDevice.deviceName.info"),
                        value = deviceName,
                        onValueChange = { deviceName = it },
                        placeholder = t("settings.crossDevice.deviceName.placeholder"),
                        enabled = !connecting,
                        keyboardType = KeyboardType.Text,
                    )
                }
            }
            item(key = "connect") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp)
                        .padding(bottom = 24.dp),
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(
                        text = t("settings.crossDevice.setup.requirement"),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Button(onClick = ::connect, enabled = !connecting) {
                        if (connecting) {
                            LoadingIndicator(modifier = Modifier.size(20.dp), color = LocalContentColor.current)
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(t("settings.crossDevice.connect"))
                    }
                }
            }
        } else {
            settingsSection(key = "connection", title = strings.t("settings.crossDevice.status")) {
                item {
                    SettingRow(
                        title = t("settings.crossDevice.currentDevice"),
                        info = t("settings.crossDevice.statusInfo"),
                        trailing = {
                            OutlinedButton(onClick = { confirmDisconnect = true }) {
                                Text(t("settings.crossDevice.disconnectShort"))
                            }
                        },
                    )
                }
                state.error?.let { error ->
                    item(key = "error") { ErrorNotice(error) }
                }
            }
        }

        if (state.devices.isNotEmpty()) {
            settingsSection(
                key = "devices",
                title = strings.t("settings.crossDevice.devices"),
                description = strings.t("settings.crossDevice.devicesDescription"),
            ) {
                for (device in state.devices) {
                    item(key = device.id) {
                        DeviceRow(
                            device = device,
                            isCurrent = device.id == state.deviceId,
                            onRename = { renaming = device },
                            onRevoke = { revoking = device },
                        )
                    }
                }
            }
        }

        if (state.isRegistered) {
            settingsSection(key = "danger") {
                item {
                    SettingRow(
                        title = t("settings.crossDevice.deleteData.label"),
                        info = t("settings.crossDevice.deleteData.info"),
                        trailing = {
                            Button(
                                onClick = { confirmDelete = true },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = MaterialTheme.colorScheme.error,
                                    contentColor = MaterialTheme.colorScheme.onError,
                                ),
                            ) {
                                Text(t("settings.crossDevice.delete"))
                            }
                        },
                    )
                }
            }
        }
    }

    if (confirmDisconnect) {
        val disconnected = t("settings.crossDevice.disconnected")
        ConfirmDialog(
            title = t("settings.crossDevice.disconnectConfirm.title"),
            description = t("settings.crossDevice.disconnectConfirm.description"),
            onDismiss = { confirmDisconnect = false },
            onConfirm = {
                confirmDisconnect = false
                act(disconnected) { coordination.disconnectThisDevice() }
            },
            confirmLabel = t("settings.crossDevice.disconnect"),
            cancelLabel = t("generic.cancel"),
        )
    }
    if (confirmDelete) {
        val deleted = t("settings.crossDevice.deleted")
        ConfirmDialog(
            title = t("settings.crossDevice.deleteConfirm.title"),
            description = t("settings.crossDevice.deleteConfirm.description"),
            onDismiss = { confirmDelete = false },
            onConfirm = {
                confirmDelete = false
                act(deleted) { coordination.deleteAccount() }
            },
            confirmLabel = t("settings.crossDevice.delete"),
            cancelLabel = t("generic.cancel"),
        )
    }
    revoking?.let { device ->
        val revoked = t("settings.crossDevice.device.revoked")
        ConfirmDialog(
            title = t("settings.crossDevice.revokeConfirm.title"),
            description = t("settings.crossDevice.revokeConfirm.description", "name" to device.name),
            onDismiss = { revoking = null },
            onConfirm = {
                revoking = null
                act(revoked) { coordination.revokeDevice(device.id) }
            },
            confirmLabel = t("settings.crossDevice.device.revoke"),
            cancelLabel = t("generic.cancel"),
        )
    }
    renaming?.let { device ->
        val renamed = t("settings.crossDevice.device.renamed")
        RenameDeviceDialog(
            device = device,
            onDismiss = { renaming = null },
            onRename = { name ->
                renaming = null
                act(renamed) { coordination.renameDevice(device.id, name) }
            },
        )
    }
}

/** The state of the connection as a colored dot and a word. */
@Composable
private fun ConnectionBadge(connection: CoordinationConnection) {
    val color = when (connection) {
        CoordinationConnection.Connected -> StatusColors.Done
        CoordinationConnection.Connecting, CoordinationConnection.Reconnecting -> StatusColors.Caution
        CoordinationConnection.Error -> StatusColors.Offline
        CoordinationConnection.Disconnected -> MaterialTheme.colorScheme.outline
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(color),
        )
        Spacer(Modifier.width(8.dp))
        TrailingValue(t("settings.crossDevice.connectionState.${connection.key}"))
    }
}

@Composable
private fun TrailingValue(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
    )
}

@Composable
private fun ErrorNotice(message: String) {
    Row(
        modifier = Modifier.padding(16.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Rounded.ErrorOutline,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )
    }
}

@Composable
private fun DeviceRow(
    device: DeviceDto,
    isCurrent: Boolean,
    onRename: () -> Unit,
    onRevoke: () -> Unit,
) {
    val strings = LocalStrings.current
    val lastOnline = device.lastOnlineAt?.let(::parseIsoTimestamp)?.let { strings.fromNow(it) }
    val details = listOfNotNull(
        device.platform.takeIf { it.isNotEmpty() },
        lastOnline?.let { t("settings.crossDevice.device.lastOnline", "time" to it) },
    ).joinToString(" · ")
    Row(
        modifier = Modifier.padding(start = 16.dp, end = 4.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            deviceIcon(device.platform),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(16.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = device.name,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (isCurrent) {
                    Spacer(Modifier.width(8.dp))
                    Surface(
                        shape = MaterialTheme.shapes.small,
                        color = MaterialTheme.colorScheme.secondaryContainer,
                    ) {
                        Text(
                            text = t("settings.crossDevice.device.current"),
                            style = MaterialTheme.typography.labelSmall,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
            }
            if (details.isNotEmpty()) {
                Text(
                    text = details,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        IconButton(onClick = onRename) {
            Icon(Icons.Rounded.Edit, contentDescription = t("settings.crossDevice.device.rename"))
        }
        if (!isCurrent) {
            IconButton(onClick = onRevoke) {
                Icon(
                    Icons.Rounded.DeleteOutline,
                    contentDescription = t("settings.crossDevice.device.revoke"),
                    tint = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@Composable
private fun RenameDeviceDialog(device: DeviceDto, onDismiss: () -> Unit, onRename: (String) -> Unit) {
    val field = rememberTextFieldState(device.name)
    val name = field.text.trim().toString()
    val canSave = name.isNotEmpty() && name != device.name
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(t("settings.crossDevice.device.rename")) },
        text = {
            OutlinedTextField(
                state = field,
                lineLimits = TextFieldLineLimits.SingleLine,
                label = { Text(t("settings.crossDevice.deviceName.label")) },
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Sentences,
                    imeAction = ImeAction.Done,
                ),
                onKeyboardAction = { if (canSave) onRename(name) },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            Button(onClick = { onRename(name) }, enabled = canSave) {
                Text(t("settings.crossDevice.device.save"))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(t("settings.crossDevice.device.cancel")) }
        },
    )
}

private fun Throwable.describe(): String = when (this) {
    is CoordinationApiException -> "$code: $message"
    else -> message ?: javaClass.simpleName
}
