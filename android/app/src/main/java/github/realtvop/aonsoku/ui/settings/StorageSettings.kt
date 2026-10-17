package github.realtvop.aonsoku.ui.settings

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.offline.PoolStats
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.plugins.audio.AudioCacheSource
import github.realtvop.aonsoku.settings.CacheSettings
import github.realtvop.aonsoku.settings.SmartDownloadRules
import github.realtvop.aonsoku.ui.components.formatBytes
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.SettingsRoute
import github.realtvop.aonsoku.ui.overlays.ConfirmDialog
import kotlinx.coroutines.launch

/** What a "Clear" button of the storage page is about to empty. */
private sealed interface ClearTarget {
    data class Pool(val source: AudioCacheSource) : ClearTarget
    data object Covers : ClearTarget
    data object Everything : ClearTarget
}

/** The route of the list of cached items, a page of its own below the storage settings. */
const val CACHE_MANAGER_PAGE = "storage-items"

/** Sync of the offline library, smart downloads, and what the caches hold. */
@Composable
internal fun StorageSettings() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val navigator = LocalNavigator.current
    val scope = rememberCoroutineScope()
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val sync by graph.sync.state.collectAsStateWithLifecycle()
    val coverSync by graph.offline.coverSync.collectAsStateWithLifecycle()
    val online by graph.network.isOnline.collectAsStateWithLifecycle()
    val pools by graph.offline.pools.collectAsStateWithLifecycle()
    val cache = settings.cache
    val rules = cache.smartRules
    var clearing by remember { mutableStateOf<ClearTarget?>(null) }

    // Images are cached as pages show them, without this page being told.
    LaunchedEffect(Unit) { graph.offline.refreshCoverStats() }

    fun updateCache(change: (CacheSettings) -> CacheSettings) =
        graph.settings.update { it.copy(cache = change(it.cache)) }

    fun updateRules(change: (SmartDownloadRules) -> SmartDownloadRules) =
        updateCache { it.copy(smartRules = change(it.smartRules)) }

    val unlimited = t("settings.storage.limits.unlimited")
    val sequential = t("settings.storage.sync.coverArtConcurrencyOff")
    val busy = sync.isSyncing || coverSync != null

    SettingsPage(title = t("settings.options.storage")) {
        settingsSection(
            key = "offline",
            title = strings.t("settings.storage.sync.group"),
            description = strings.t("settings.storage.sync.description"),
        ) {
            item {
                SwitchSetting(
                    title = t("settings.storage.sync.coverArt"),
                    info = t("settings.storage.sync.coverArtInfo"),
                    checked = cache.syncCoverArt,
                    onCheckedChange = { enabled -> updateCache { it.copy(syncCoverArt = enabled) } },
                )
            }
            item {
                SliderSetting(
                    title = t("settings.storage.sync.coverArtConcurrency"),
                    info = t("settings.storage.sync.coverArtConcurrencyInfo"),
                    value = cache.coverArtConcurrency,
                    onValueChange = { value -> updateCache { it.copy(coverArtConcurrency = value) } },
                    range = CacheSettings.COVER_ART_CONCURRENCY_MIN..CacheSettings.COVER_ART_CONCURRENCY_MAX,
                    enabled = cache.syncCoverArt,
                    valueLabel = { if (it == CacheSettings.COVER_ART_CONCURRENCY_MIN) sequential else it.toString() },
                )
            }
            item {
                val progress = coverSync
                val status = when {
                    progress != null ->
                        "${t("settings.storage.sync.phases.coverArt")} ${progress.percent}%"
                    sync.isSyncing -> t("settings.storage.sync.phases.${sync.phase}")
                    cache.lastSyncedAt == null -> t("settings.storage.sync.never")
                    else -> strings.fromNow(cache.lastSyncedAt)
                }
                SettingRow(
                    title = t("settings.storage.sync.lastSynced"),
                    info = status,
                    trailing = {
                        if (busy) {
                            OutlinedButton(
                                onClick = {
                                    graph.sync.cancel()
                                    graph.offline.cancelCoverSync()
                                },
                            ) {
                                Text(t("settings.storage.sync.cancel"))
                            }
                        } else {
                            OutlinedButton(onClick = { graph.sync.syncNow() }, enabled = online) {
                                Text(t("settings.storage.sync.syncNow"))
                            }
                        }
                    },
                )
            }
        }

        settingsSection(
            key = "smart",
            title = strings.t("settings.storage.smart.group"),
            description = strings.t("settings.storage.smart.description"),
        ) {
            item {
                SwitchSetting(
                    title = t("settings.storage.smart.enabled"),
                    checked = rules.enabled,
                    onCheckedChange = { enabled -> updateRules { it.copy(enabled = enabled) } },
                )
            }
            // A rule only counts while smart downloads are on, and shows as much.
            item {
                SwitchSetting(
                    title = t("settings.storage.smart.rule.favoriteSongs"),
                    checked = rules.enabled && rules.favoriteSongs,
                    enabled = rules.enabled,
                    onCheckedChange = { enabled -> updateRules { it.copy(favoriteSongs = enabled) } },
                )
            }
            item {
                SwitchSetting(
                    title = t("settings.storage.smart.rule.favoritePlaylists"),
                    checked = rules.enabled && rules.favoritePlaylists,
                    enabled = rules.enabled,
                    onCheckedChange = { enabled -> updateRules { it.copy(favoritePlaylists = enabled) } },
                )
            }
        }

        settingsSection(
            key = "limits",
            title = strings.t("settings.storage.limits.group"),
            description = strings.t("settings.storage.limits.description"),
        ) {
            for (source in listOf(AudioCacheSource.Explicit, AudioCacheSource.Smart, AudioCacheSource.Lru)) {
                item(key = source.id) {
                    val stats = pools.audio(source)
                    PoolRow(
                        pool = source.id,
                        stats = stats,
                        entries = t("settings.storage.limits.songEntries", "count" to stats.count),
                        // Only what is kept while listening has a size to stay under.
                        quota = cache.lruQuota.takeIf { source == AudioCacheSource.Lru },
                        unlimited = unlimited,
                        onQuotaChange = { bytes -> updateCache { it.copy(lruQuota = bytes) } },
                        clearEnabled = stats.count > 0,
                        onClear = { clearing = ClearTarget.Pool(source) },
                    )
                }
            }
            item(key = "assets") {
                PoolRow(
                    pool = "assets",
                    stats = pools.covers,
                    entries = t("settings.storage.limits.imageEntries", "count" to pools.covers.count),
                    quota = cache.assetsQuota,
                    unlimited = unlimited,
                    onQuotaChange = { bytes -> updateCache { it.copy(assetsQuota = bytes) } },
                    clearEnabled = pools.covers.count > 0,
                    onClear = { clearing = ClearTarget.Covers },
                )
            }
        }
        item(key = "clear-all") {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 24.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Button(
                    onClick = { clearing = ClearTarget.Everything },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError,
                    ),
                ) {
                    Text(t("settings.storage.limits.clearAll"))
                }
            }
        }

        settingsSection(
            key = "manager",
            title = strings.t("settings.storage.cacheManager.group"),
            description = strings.t("settings.storage.cacheManager.description"),
        ) {
            item {
                val count = pools.explicit.count + pools.smart.count + pools.lru.count + pools.covers.count
                val size = pools.explicit.sizeBytes + pools.smart.sizeBytes + pools.lru.sizeBytes +
                    pools.covers.sizeBytes
                SettingRow(
                    title = t("settings.storage.cacheManager.group"),
                    info = t(
                        "settings.storage.cacheManager.list.total",
                        "count" to count,
                        "size" to formatBytes(size),
                    ),
                    onClick = { navigator.open(SettingsRoute(CACHE_MANAGER_PAGE)) },
                    trailing = {
                        Icon(
                            Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    },
                )
            }
        }
    }

    clearing?.let { target ->
        val everything = target == ClearTarget.Everything
        val name = when (target) {
            is ClearTarget.Pool -> t("settings.storage.limits.pool.${target.source.id}.label")
            ClearTarget.Covers -> t("settings.storage.limits.pool.assets.label")
            ClearTarget.Everything -> ""
        }
        ConfirmDialog(
            title = t(
                if (everything) "settings.storage.limits.clearAll" else "settings.storage.cacheManager.confirmDelete.title",
            ),
            description = if (everything) {
                t("settings.storage.metadata.description")
            } else {
                t("settings.storage.cacheManager.confirmDelete.description", "name" to name)
            },
            confirmLabel = t("settings.storage.limits.clearAudio"),
            cancelLabel = t("generic.cancel"),
            onDismiss = { clearing = null },
            onConfirm = {
                clearing = null
                scope.launch {
                    when (target) {
                        is ClearTarget.Pool -> graph.offline.clearPool(target.source)
                        ClearTarget.Covers -> graph.offline.clearCovers()
                        ClearTarget.Everything -> {
                            graph.sync.cancel()
                            graph.offline.clearAll()
                        }
                    }
                }
            },
        )
    }
}

/** One pool of the cache: what it is for, what it holds, its size limit, and a way to empty it. */
@Composable
private fun PoolRow(
    pool: String,
    stats: PoolStats,
    entries: String,
    /** The limit in bytes, 0 for none; null for a pool that has no limit to set. */
    quota: Long?,
    unlimited: String,
    onQuotaChange: (Long) -> Unit,
    clearEnabled: Boolean,
    onClear: () -> Unit,
) {
    val label = t("settings.storage.limits.pool.$pool.label")
    val clear = t("settings.storage.limits.clearAudio")
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        SettingText(title = label, info = t("settings.storage.limits.pool.$pool.description"))
        Text(
            text = "${formatBytes(stats.sizeBytes)} · $entries",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp),
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (quota == null) {
                Text(
                    text = unlimited,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                QuotaPicker(
                    label = "$label: ${t("settings.storage.limits.quota")}",
                    quota = quota,
                    unlimited = unlimited,
                    onChange = onQuotaChange,
                )
            }
            Spacer(Modifier.weight(1f))
            OutlinedButton(
                onClick = onClear,
                enabled = clearEnabled,
                // Four buttons say "Clear"; each also says what it clears.
                modifier = Modifier.semantics { contentDescription = "$label: $clear" },
            ) {
                Text(clear)
            }
        }
    }
}

/** The sizes a pool may be limited to, in a menu that opens from the current one. */
@Composable
private fun QuotaPicker(label: String, quota: Long, unlimited: String, onChange: (Long) -> Unit) {
    var open by remember { mutableStateOf(false) }
    fun name(bytes: Long, known: String) = if (bytes == 0L) unlimited else known
    val current = CacheSettings.SIZE_OPTIONS.firstOrNull { it.first == quota }
        ?.let { name(it.first, it.second) }
        ?: formatBytes(quota)
    Box {
        OutlinedButton(
            onClick = { open = true },
            modifier = Modifier.semantics { contentDescription = "$label, $current" },
            contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
        ) {
            Text(current)
            Spacer(Modifier.width(4.dp))
            Icon(Icons.Rounded.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for ((bytes, known) in CacheSettings.SIZE_OPTIONS) {
                DropdownMenuItem(
                    text = { Text(name(bytes, known)) },
                    onClick = {
                        open = false
                        onChange(bytes)
                    },
                )
            }
        }
    }
}
