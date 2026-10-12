package github.realtvop.aonsoku.ui.components

import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowCircleDown
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.plugins.audio.AudioCacheSource
import github.realtvop.aonsoku.plugins.audio.AudioDownload
import github.realtvop.aonsoku.plugins.audio.CachedAudio
import github.realtvop.aonsoku.theme.StatusColors
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** What is known about [songId] being kept on the device. */
@Composable
fun rememberCachedAudio(songId: String): CachedAudio? {
    val offline = LocalAppGraph.current.offline
    val flow = remember(offline, songId) { offline.cached.map { it[songId] }.distinctUntilChanged() }
    val value by flow.collectAsStateWithLifecycle(offline.cached.value[songId])
    return value
}

/** The download of [songId] while it waits or runs. */
@Composable
fun rememberDownload(songId: String): AudioDownload? {
    val offline = LocalAppGraph.current.offline
    val flow = remember(offline, songId) { offline.downloads.map { it[songId] }.distinctUntilChanged() }
    val value by flow.collectAsStateWithLifecycle(offline.downloads.value[songId])
    return value
}

/**
 * Says at the end of a song row whether the song plays without a network: a
 * ring while it downloads, a mark once it is kept (its shape tells who decided
 * to keep it), and nothing for a song that still needs the server.
 */
@Composable
fun CachedIndicator(
    songId: String,
    modifier: Modifier = Modifier,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    val download = rememberDownload(songId)
    val cached = rememberCachedAudio(songId)
    when {
        download != null -> DownloadRing(download.fraction, tint, modifier)
        cached == null -> Unit
        cached.removedFromServer -> Icon(
            Icons.Rounded.ErrorOutline,
            contentDescription = t("offline.badge.orphan"),
            tint = StatusColors.Caution,
            modifier = modifier.size(IndicatorSize),
        )
        cached.source == AudioCacheSource.Smart -> Icon(
            Icons.Rounded.AutoAwesome,
            contentDescription = t("offline.badge.smart"),
            // Green: the app, not the user, decided to keep this one.
            tint = StatusColors.Done,
            modifier = modifier.size(IndicatorSize),
        )
        else -> Icon(
            Icons.Rounded.ArrowCircleDown,
            contentDescription = t("offline.badge.downloaded"),
            tint = tint,
            modifier = modifier.size(IndicatorSize),
        )
    }
}

/** A ring that fills with the download; empty while the download waits for its turn. */
@Composable
fun DownloadRing(fraction: Float?, tint: Color, modifier: Modifier = Modifier) {
    val label = t("offline.badge.downloading")
    CircularProgressIndicator(
        progress = { fraction ?: 0f },
        modifier = modifier
            .size(IndicatorSize - 2.dp)
            .semantics { contentDescription = label },
        color = tint,
        strokeWidth = 2.dp,
        trackColor = tint.copy(alpha = 0.25f),
        strokeCap = StrokeCap.Round,
        gapSize = 0.dp,
    )
}

private val IndicatorSize = 16.dp
