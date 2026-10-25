package github.realtvop.aonsoku.ui.shell

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.offline.CoverSyncProgress
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.plugins.audio.AudioDownload
import github.realtvop.aonsoku.plugins.data.LibrarySyncState
import github.realtvop.aonsoku.theme.StatusColors
import github.realtvop.aonsoku.ui.components.DownloadRing
import github.realtvop.aonsoku.ui.components.formatBytes

/** The steps of a library sync, each made of the phases the sync engine reports. */
enum class SyncTier(val id: String, private val phases: List<Pair<String, Float>>) {
    Essentials("t1", listOf("genres" to 0.2f, "playlists" to 0.5f, "favorites" to 0.3f)),
    Skeleton("t2", listOf("artists" to 0.3f, "albums" to 0.7f)),
    Songs("t3", listOf("songs" to 1f)),
    ;

    /**
     * How far this tier is, in percent, while [phase] runs and is itself at
     * [phaseProgress] percent: the phases before it count in full.
     */
    fun progress(phase: String, phaseProgress: Int): Int {
        val index = phases.indexOfFirst { it.first == phase }
        if (index < 0) return 0
        val before = phases.take(index).sumOf { it.second.toDouble() }
        val current = phases[index].second * phaseProgress.coerceIn(0, 100) / 100.0
        return ((before + current) * 100).toInt().coerceIn(0, 100)
    }

    companion object {
        fun of(id: String?): SyncTier? = entries.firstOrNull { it.id == id }
    }
}

enum class TierStatus { Pending, Running, Done, Error }

/** What [tier] is doing in a sync that reports [phase] for the tier [current]. */
fun tierStatus(tier: SyncTier, phase: String, current: SyncTier?): TierStatus = when {
    // A cancelled sync shows no tier as left over, like the web app.
    phase == "done" || phase == "cancelled" -> TierStatus.Done
    current == null -> TierStatus.Pending
    tier.ordinal < current.ordinal -> TierStatus.Done
    tier.ordinal > current.ordinal -> TierStatus.Pending
    phase == "error" -> TierStatus.Error
    else -> TierStatus.Running
}

/** What the small mark on the account picture stands for. */
enum class SyncBadge(val color: Color, val icon: ImageVector) {
    Offline(StatusColors.Offline, Icons.Rounded.WifiOff),
    Error(StatusColors.Caution, Icons.Rounded.WarningAmber),
    Syncing(StatusColors.Active, Icons.Rounded.Sync),
    Done(StatusColors.Done, Icons.Rounded.Check),
}

fun syncBadge(online: Boolean, sync: LibrarySyncState, coverSync: CoverSyncProgress?): SyncBadge? = when {
    !online -> SyncBadge.Offline
    sync.phase == "error" -> SyncBadge.Error
    sync.isSyncing || coverSync != null -> SyncBadge.Syncing
    sync.phase == "done" -> SyncBadge.Done
    else -> null
}

@Composable
fun rememberSyncBadge(): SyncBadge? {
    val graph = LocalAppGraph.current
    val online by graph.network.isOnline.collectAsStateWithLifecycle()
    val sync by graph.sync.state.collectAsStateWithLifecycle()
    val coverSync by graph.offline.coverSync.collectAsStateWithLifecycle()
    return syncBadge(online, sync, coverSync)
}

/** The mark itself, to be laid over the corner of an account picture. */
@Composable
fun SyncBadgeDot(badge: SyncBadge, modifier: Modifier = Modifier, size: Dp = 14.dp) {
    val label = when (badge) {
        SyncBadge.Offline -> t("offline.mode")
        SyncBadge.Error -> t("settings.storage.sync.phases.error")
        SyncBadge.Syncing -> t("settings.storage.sync.syncNow")
        SyncBadge.Done -> t("settings.storage.sync.phases.done")
    }
    Box(
        modifier = modifier
            .size(size)
            .border(2.dp, MaterialTheme.colorScheme.background, CircleShape)
            .padding(2.dp)
            .clip(CircleShape)
            .background(badge.color)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            badge.icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier
                .size(size - 6.dp)
                .then(if (badge == SyncBadge.Syncing) Modifier.rotate(rememberTurn()) else Modifier),
        )
    }
}

/** The angle of something that keeps turning. */
@Composable
private fun rememberTurn(): Float {
    val transition = rememberInfiniteTransition(label = "syncTurn")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = -360f,
        animationSpec = infiniteRepeatable(tween(1_200, easing = LinearEasing), RepeatMode.Restart),
        label = "syncTurnAngle",
    )
    return angle
}

/**
 * The state of the offline library in the account sheet: that the server is
 * out of reach, or how the sync is doing tier by tier, what is downloading,
 * and a button to sync now.
 */
@Composable
fun SyncSection(modifier: Modifier = Modifier) {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val online by graph.network.isOnline.collectAsStateWithLifecycle()
    val sync by graph.sync.state.collectAsStateWithLifecycle()
    val coverSync by graph.offline.coverSync.collectAsStateWithLifecycle()
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val downloads by graph.offline.downloads.collectAsStateWithLifecycle()

    if (!online) {
        Column(modifier = modifier.padding(horizontal = 24.dp, vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Rounded.WifiOff,
                    contentDescription = null,
                    tint = StatusColors.Offline,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = t("offline.mode"),
                    style = MaterialTheme.typography.labelLarge,
                    color = StatusColors.Offline,
                )
            }
            Text(
                text = t("offline.disconnected"),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        return
    }

    val failed = sync.phase == "error"
    val busy = sync.isSyncing || coverSync != null
    val title = when (sync.phase) {
        "idle" -> t("settings.storage.sync.group")
        "done" -> t("settings.storage.sync.phases.done")
        "error" -> t("settings.storage.sync.phases.error")
        "cancelled" -> t("settings.storage.sync.phases.cancelled")
        else -> t("settings.storage.sync.phases.idle")
    }
    val lastSyncedAt = settings.cache.lastSyncedAt
    val syncedText = when {
        lastSyncedAt == null -> t("settings.storage.sync.never")
        System.currentTimeMillis() - lastSyncedAt < 60_000 -> t("settings.storage.sync.justNow")
        else -> strings.fromNow(lastSyncedAt)
    }

    Column(modifier = modifier.padding(horizontal = 24.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(text = title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
            Text(
                text = syncedText,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(8.dp))
        val current = SyncTier.of(sync.tier)
        for (tier in SyncTier.entries) {
            val status = tierStatus(tier, sync.phase, current)
            StepRow(
                status = status,
                label = t("settings.storage.sync.tier.${tier.id}.label"),
                description = t("settings.storage.sync.tier.${tier.id}.description"),
                activity = t("settings.storage.sync.phases.${sync.phase}"),
                percent = tier.progress(sync.phase, sync.progress),
            )
        }
        if (settings.cache.syncCoverArt) {
            val progress = coverSync
            StepRow(
                status = when {
                    progress != null -> TierStatus.Running
                    sync.phase == "done" -> TierStatus.Done
                    else -> TierStatus.Pending
                },
                label = t("settings.storage.sync.tier.coverArt.label"),
                description = t("settings.storage.sync.tier.coverArt.description"),
                activity = t("settings.storage.sync.phases.coverArt"),
                percent = progress?.percent ?: 0,
                runningIcon = Icons.Rounded.Image,
            )
        }
        ActiveDownloads(downloads.values.toList())
        Spacer(Modifier.height(12.dp))
        val start = { graph.sync.syncNow(full = true) }
        val label: @Composable () -> Unit = {
            Icon(
                Icons.Rounded.Sync,
                contentDescription = null,
                modifier = Modifier
                    .size(16.dp)
                    .then(if (busy) Modifier.rotate(rememberTurn()) else Modifier),
            )
            Spacer(Modifier.width(8.dp))
            Text(t("settings.storage.sync.syncNow"))
        }
        // A failed sync makes trying again the thing to do.
        if (failed) {
            Button(onClick = { start() }, enabled = !busy, modifier = Modifier.fillMaxWidth(), content = { label() })
        } else {
            OutlinedButton(
                onClick = { start() },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
                content = { label() },
            )
        }
    }
}

@Composable
private fun StepRow(
    status: TierStatus,
    label: String,
    description: String,
    activity: String,
    percent: Int,
    runningIcon: ImageVector = Icons.Rounded.Sync,
) {
    val color = when (status) {
        TierStatus.Done -> StatusColors.Done
        TierStatus.Running -> StatusColors.Active
        TierStatus.Error -> StatusColors.Caution
        TierStatus.Pending -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row(modifier = Modifier.padding(vertical = 4.dp)) {
        Box(
            modifier = Modifier
                .padding(top = 1.dp)
                .size(20.dp)
                .clip(CircleShape)
                .background(if (status == TierStatus.Pending) Color.Transparent else color.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            when (status) {
                TierStatus.Pending -> Box(Modifier.size(6.dp).clip(CircleShape).background(color))
                TierStatus.Done -> Icon(Icons.Rounded.Check, null, tint = color, modifier = Modifier.size(12.dp))
                TierStatus.Error -> Icon(Icons.Rounded.WarningAmber, null, tint = color, modifier = Modifier.size(12.dp))
                TierStatus.Running -> Icon(runningIcon, null, tint = color, modifier = Modifier.size(12.dp))
            }
        }
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = label,
                    style = MaterialTheme.typography.labelLarge,
                    color = if (status == TierStatus.Pending) {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                    modifier = Modifier.weight(1f),
                )
                if (status == TierStatus.Running) {
                    Text(
                        text = "$percent%",
                        style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (status == TierStatus.Running) {
                Text(text = activity, style = MaterialTheme.typography.bodySmall, color = color, maxLines = 1)
                LinearProgressIndicator(
                    progress = { percent / 100f },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp)
                        .height(4.dp),
                    color = color,
                    trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                )
            }
        }
    }
}

/** The songs that are downloading: the first few by name, the rest on request. */
@Composable
private fun ActiveDownloads(downloads: List<AudioDownload>) {
    if (downloads.isEmpty()) return
    val graph = LocalAppGraph.current
    var expanded by remember { mutableStateOf(false) }
    val names = remember { mutableStateMapOf<String, String>() }
    val shown = if (expanded) downloads else downloads.take(DOWNLOAD_PREVIEW)
    LaunchedEffect(shown.map { it.songId }) {
        for (download in shown) {
            if (download.songId in names) continue
            val song = runSuspendCatching { graph.library.localSong(download.songId) }.getOrNull()
            names[download.songId] = song?.title?.takeIf { it.isNotEmpty() } ?: download.songId
        }
    }
    Row(modifier = Modifier.padding(top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(20.dp)
                .clip(CircleShape)
                .background(StatusColors.Active.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Rounded.Sync,
                contentDescription = null,
                tint = StatusColors.Active,
                modifier = Modifier
                    .size(12.dp)
                    .rotate(rememberTurn()),
            )
        }
        Spacer(Modifier.width(10.dp))
        Text(
            text = plural("settings.storage.sync.downloading", downloads.size),
            style = MaterialTheme.typography.labelLarge,
        )
    }
    Column(modifier = Modifier.padding(start = 30.dp)) {
        for (download in shown) {
            Row(modifier = Modifier.padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = names[download.songId] ?: "…",
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                val fraction = download.fraction
                if (fraction != null || download.loaded > 0) {
                    Text(
                        text = fraction?.let { "${(it * 100).toInt()}%" } ?: formatBytes(download.loaded, decimals = 1),
                        style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 8.dp),
                    )
                }
                DownloadRing(fraction, MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (downloads.size > DOWNLOAD_PREVIEW && !expanded) {
            Text(
                text = t("settings.storage.sync.showMore", "count" to downloads.size - DOWNLOAD_PREVIEW),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .clip(MaterialTheme.shapes.small)
                    .clickable { expanded = true }
                    .padding(vertical = 6.dp),
            )
        }
    }
}

private const val DOWNLOAD_PREVIEW = 3
