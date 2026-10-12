package github.realtvop.aonsoku.ui.shell

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import github.realtvop.aonsoku.BuildConfig
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.login.AppTitle
import java.text.DateFormat
import java.util.Date

@Composable
fun AboutDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { AppTitle() },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                AboutSection(title = t("about.client")) {
                    AboutRow(label = t("about.version")) {
                        AboutChip(BuildConfig.APP_VERSION, highlighted = true)
                        if (BuildConfig.BUILD_HASH.isNotEmpty()) {
                            AboutChip(BuildConfig.BUILD_HASH, monospace = true)
                        }
                    }
                    if (BuildConfig.BUILD_TIME > 0) {
                        AboutRow(label = t("about.buildTime")) {
                            AboutChip(
                                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                                    .format(Date(BuildConfig.BUILD_TIME)),
                                monospace = true,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    runCatching {
                        context.startActivity(
                            Intent(Intent.ACTION_VIEW, BuildConfig.REPOSITORY_URL.toUri()),
                        )
                    }
                },
            ) {
                Text("GitHub")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(t("generic.cancel")) }
        },
    )
}

@Composable
internal fun AboutSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurface,
        )
        content()
    }
}

@Composable
internal fun AboutRow(label: String, chips: @Composable () -> Unit) {
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        itemVerticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        chips()
    }
}

@Composable
internal fun AboutChip(
    text: String,
    highlighted: Boolean = false,
    monospace: Boolean = false,
) {
    Surface(
        shape = CircleShape,
        color = if (highlighted) {
            MaterialTheme.colorScheme.primaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainerHighest
        },
        contentColor = if (highlighted) {
            MaterialTheme.colorScheme.onPrimaryContainer
        } else {
            MaterialTheme.colorScheme.onSurfaceVariant
        },
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelMedium,
            fontFamily = if (monospace) FontFamily.Monospace else null,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp),
        )
    }
}
