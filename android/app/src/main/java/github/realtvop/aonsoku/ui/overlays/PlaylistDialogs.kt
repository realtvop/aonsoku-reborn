package github.realtvop.aonsoku.ui.overlays

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t

private const val MIN_PLAYLIST_NAME_LENGTH = 2

/** Create or edit a playlist: name, comment, and public visibility. */
@Composable
fun PlaylistFormDialog(overlay: Overlay.PlaylistForm, controller: OverlayController) {
    val graph = LocalAppGraph.current
    val editing = overlay.playlist
    var name by rememberSaveable { mutableStateOf(editing?.name.orEmpty()) }
    var comment by rememberSaveable { mutableStateOf(editing?.comment.orEmpty()) }
    // New playlists are public by default, as in the web form.
    var isPublic by rememberSaveable { mutableStateOf(editing?.isPublic ?: true) }
    var submitted by rememberSaveable { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    val nameValid = name.trim().length >= MIN_PLAYLIST_NAME_LENGTH

    fun submit() {
        submitted = true
        if (!nameValid || saving) return
        saving = true
        // A failed request reports through a toast; the form stays open for another attempt.
        val failed = { saving = false }
        if (editing == null) {
            graph.actions.createPlaylist(
                name = name.trim(),
                comment = comment.trim(),
                isPublic = isPublic,
                onDone = controller::dismiss,
                onFailed = failed,
            )
        } else {
            graph.actions.updatePlaylist(
                id = editing.id,
                name = name.trim(),
                comment = comment.trim(),
                isPublic = isPublic,
                onDone = controller::dismiss,
                onFailed = failed,
            )
        }
    }

    AlertDialog(
        onDismissRequest = controller::dismiss,
        title = {
            Text(t(if (editing == null) "playlist.form.create.title" else "playlist.form.edit.title"))
        },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(t("playlist.form.labels.name")) },
                    singleLine = true,
                    isError = submitted && !nameValid,
                    supportingText = if (submitted && !nameValid) {
                        { Text(t("playlist.form.validations.nameLength")) }
                    } else {
                        null
                    },
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Sentences,
                        imeAction = ImeAction.Next,
                    ),
                )
                OutlinedTextField(
                    value = comment,
                    onValueChange = { comment = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(t("playlist.form.labels.comment")) },
                    supportingText = { Text(t("playlist.form.labels.commentDescription")) },
                    minLines = 2,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Sentences,
                    ),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = t("playlist.form.labels.isPublic"),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = t("playlist.form.labels.isPublicDescription"),
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Switch(checked = isPublic, onCheckedChange = { isPublic = it })
                }
            }
        },
        confirmButton = {
            Button(onClick = ::submit, enabled = !saving) {
                Text(
                    t(
                        if (editing == null) {
                            "playlist.form.create.button"
                        } else {
                            "playlist.form.edit.button"
                        },
                    ),
                )
            }
        },
        dismissButton = {
            TextButton(onClick = controller::dismiss) { Text(t("generic.cancel")) }
        },
    )
}

@Composable
fun DeletePlaylistDialog(overlay: Overlay.DeletePlaylist, controller: OverlayController) {
    val graph = LocalAppGraph.current
    ConfirmDialog(
        title = t("playlist.form.delete.title"),
        description = t("playlist.form.delete.description"),
        onDismiss = controller::dismiss,
        onConfirm = {
            controller.dismiss()
            graph.actions.deletePlaylist(overlay.playlist.id) { overlay.onDeleted?.invoke() }
        },
    )
}

@Composable
fun RemoveFromPlaylistDialog(overlay: Overlay.RemoveFromPlaylist, controller: OverlayController) {
    val graph = LocalAppGraph.current
    ConfirmDialog(
        title = plural("playlist.form.removeSong.title", overlay.indexes.size),
        description = t("playlist.form.removeSong.description"),
        onDismiss = controller::dismiss,
        onConfirm = {
            controller.dismiss()
            graph.actions.removeFromPlaylist(overlay.playlistId, overlay.indexes)
        },
    )
}

/** Destructive confirmation; the buttons say "Cancel" and "Continue" unless told otherwise. */
@Composable
fun ConfirmDialog(
    title: String,
    description: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
    confirmLabel: String = t("logout.dialog.confirm"),
    cancelLabel: String = t("logout.dialog.cancel"),
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(description) },
        confirmButton = {
            Button(onClick = onConfirm) { Text(confirmLabel) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(cancelLabel) }
        },
    )
}
