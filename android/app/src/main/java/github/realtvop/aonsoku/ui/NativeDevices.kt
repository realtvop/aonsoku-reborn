package github.realtvop.aonsoku.ui

import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun DeviceScreen(model: AonsokuViewModel) {
    val controller = model.coordinator
    val devices by controller.devices.collectAsState()
    val state by controller.state.collectAsState()
    val enabled by controller.enabled.collectAsState()
    val controlled by controller.controlledDeviceId.collectAsState()
    val config = controller.transport.loadConfig()
    Column {
        ListItem(headlineContent = { Text(L("Cross-device playback")) }, supportingContent = { Text(state) }, trailingContent = { Switch(enabled, { if (it && config != null) controller.configure(config.first, config.second, model.preference("native.coordination.deviceName") ?: Build.MODEL) else if (!it) controller.disconnect() else model.coordinationForm() }) })
        ActionRow("Connection settings", Icons.Default.Settings) { model.coordinationForm() }
        ActionRow("Refresh devices", Icons.Default.Refresh) { controller.refreshDevices(); controller.transport.requestPeerSnapshots() }
        if (controlled != null) ActionRow("Control this device", Icons.Default.PhoneAndroid) { controller.control(null) }
        devices.forEach { device ->
            val current = device.id == controller.deviceId
            ElevatedCard(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp)) {
                Column(Modifier.padding(16.dp)) {
                    Row { Icon(if (device.platform == "android" || device.platform == "ios") Icons.Default.PhoneAndroid else Icons.Default.Computer, null); Spacer(Modifier.width(12.dp)); Column(Modifier.weight(1f)) { Text(device.name, style = MaterialTheme.typography.titleMedium); Text(if (current) L("This device") else if (device.online) L("Online") else L("Offline"), style = MaterialTheme.typography.labelMedium) } }
                    device.snapshot?.let { snapshot -> Text("${snapshot.optString("songId")} · ${formatTime(snapshot.optDouble("progressSeconds"))}", style = MaterialTheme.typography.bodySmall) }
                    if (!current && device.online) Row {
                        TextButton({ controller.control(device.id) }) { Text(L(if (controlled == device.id) "Controlling" else "Control")) }
                        TextButton({ model.launch { controller.handoff(device.id) } }) { Text(L("Continue here")) }
                    }
                    Row {
                        TextButton({ model.dialog.value = NativeDialog.Form("Rename device", listOf(NativeField("name", "Name", device.name))) { values -> controller.rename(device.id, values["name"].orEmpty()) } }) { Text(L("Rename")) }
                        TextButton({ model.dialog.value = NativeDialog.Confirm("Revoke device?", device.name) { model.launch { controller.revoke(device.id) } } }) { Text(L("Revoke")) }
                    }
                }
            }
        }
        ActionRow("Delete coordination account", Icons.Default.DeleteForever) { model.dialog.value = NativeDialog.Confirm("Delete coordination account?", "All devices and synchronized history will be removed from the coordination server.") { model.launch { controller.deleteAccount() } } }
    }
}
fun AonsokuViewModel.coordinationForm() {
    val config = coordinator.transport.loadConfig()
    dialog.value = NativeDialog.Form("Cross-device connection", listOf(NativeField("server", "Coordination server URL", config?.first.orEmpty()), NativeField("identity", "Identity server URL", config?.second ?: services.authentication.getCredentials()?.serverUrl.orEmpty()), NativeField("name", "Device name", preference("native.coordination.deviceName") ?: Build.MODEL))) { values -> coordinator.configure(values["server"].orEmpty(), values["identity"].orEmpty(), values["name"].orEmpty()) }
}
