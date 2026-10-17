package github.realtvop.aonsoku.ui.player

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.t

/**
 * Asks what to do with manually queued songs before a new selection replaces
 * the queue: replace it, or play the selection after the current song.
 */
@Composable
fun QueueReplacementDialog() {
    val player = LocalAppGraph.current.player
    val request by player.pendingReplacement.collectAsStateWithLifecycle()
    if (request == null) return

    AlertDialog(
        onDismissRequest = player::dismissReplacement,
        title = { Text(t("queue.replacementConfirmation.title")) },
        text = { Text(t("queue.replacementConfirmation.description")) },
        confirmButton = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(
                    onClick = { player.confirmReplacement(replaceQueue = true) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(t("queue.replacementConfirmation.replace"))
                }
                FilledTonalButton(
                    onClick = { player.confirmReplacement(replaceQueue = false) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(t("queue.replacementConfirmation.playNext"))
                }
                TextButton(
                    onClick = player::dismissReplacement,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(t("generic.cancel"))
                }
            }
        },
    )
}
