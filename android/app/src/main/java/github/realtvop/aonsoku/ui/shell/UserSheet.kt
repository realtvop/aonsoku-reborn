package github.realtvop.aonsoku.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.image.AvatarArt
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.session.SessionState
import github.realtvop.aonsoku.ui.components.rememberExpandedSheetState
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.SettingsRoute
import kotlinx.coroutines.launch

/** Account button shown in page headers; opens the account sheet. */
@Composable
fun UserAvatarButton(modifier: Modifier = Modifier) {
    var sheetOpen by remember { mutableStateOf(false) }
    IconButton(onClick = { sheetOpen = true }, modifier = modifier) {
        UserAvatar(size = 32)
    }
    if (sheetOpen) {
        UserSheet(onDismiss = { sheetOpen = false })
    }
}

@Composable
fun UserAvatar(size: Int, modifier: Modifier = Modifier) {
    val graph = LocalAppGraph.current
    val session by graph.session.state.collectAsStateWithLifecycle()
    val username = (session as? SessionState.SignedIn)?.credentials?.username.orEmpty()
    var loaded by remember(username) { mutableStateOf(false) }
    Box(
        modifier = modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        contentAlignment = Alignment.Center,
    ) {
        if (!loaded) {
            Icon(
                imageVector = Icons.Rounded.Person,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size((size * 0.6f).dp),
            )
        }
        if (username.isNotEmpty()) {
            AsyncImage(
                model = AvatarArt(username),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                onSuccess = { loaded = true },
                onError = { loaded = false },
            )
        }
    }
}

@Composable
private fun UserSheet(onDismiss: () -> Unit) {
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val session by graph.session.state.collectAsStateWithLifecycle()
    val credentials = (session as? SessionState.SignedIn)?.credentials
    val sheetState = rememberExpandedSheetState()
    val scope = rememberCoroutineScope()
    var aboutOpen by remember { mutableStateOf(false) }
    var logoutOpen by remember { mutableStateOf(false) }

    fun close(then: () -> Unit = {}) {
        scope.launch { sheetState.hide() }.invokeOnCompletion {
            onDismiss()
            then()
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.navigationBarsPadding().padding(bottom = 12.dp)) {
            Row(
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                UserAvatar(size = 44)
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(
                        text = credentials?.username.orEmpty(),
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = credentials?.serverUrl.orEmpty(),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            HorizontalDivider()
            Spacer(Modifier.height(8.dp))
            SheetAction(
                icon = Icons.Rounded.Settings,
                label = t("settings.label"),
                onClick = { close { navigator.open(SettingsRoute()) } },
            )
            SheetAction(
                icon = Icons.Rounded.Info,
                label = t("menu.about"),
                onClick = { aboutOpen = true },
            )
            SheetAction(
                icon = Icons.AutoMirrored.Rounded.Logout,
                label = t("menu.serverLogout"),
                tint = MaterialTheme.colorScheme.error,
                onClick = { logoutOpen = true },
            )
        }
    }

    if (aboutOpen) {
        AboutDialog(onDismiss = { aboutOpen = false })
    }

    if (logoutOpen) {
        AlertDialog(
            onDismissRequest = { logoutOpen = false },
            title = { Text(t("logout.dialog.title")) },
            text = { Text(t("logout.dialog.description")) },
            confirmButton = {
                TextButton(
                    onClick = {
                        logoutOpen = false
                        onDismiss()
                        graph.scope.launch { graph.signOut() }
                    },
                ) {
                    Text(t("logout.dialog.confirm"))
                }
            },
            dismissButton = {
                TextButton(onClick = { logoutOpen = false }) {
                    Text(t("logout.dialog.cancel"))
                }
            },
        )
    }
}

@Composable
private fun SheetAction(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    tint: Color = MaterialTheme.colorScheme.onSurface,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .clip(MaterialTheme.shapes.large)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(16.dp))
        Text(text = label, style = MaterialTheme.typography.bodyLarge, color = tint)
    }
}
