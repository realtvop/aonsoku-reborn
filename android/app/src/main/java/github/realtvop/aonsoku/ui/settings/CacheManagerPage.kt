package github.realtvop.aonsoku.ui.settings

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.offline.CachedItem
import github.realtvop.aonsoku.data.offline.CachedItemType
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.plugins.audio.AudioCacheSource
import github.realtvop.aonsoku.theme.StatusColors
import github.realtvop.aonsoku.ui.components.EmptyState
import github.realtvop.aonsoku.ui.components.PageLoading
import github.realtvop.aonsoku.ui.components.PageTitle
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.components.formatBytes
import github.realtvop.aonsoku.ui.components.rememberTitleCollapsed
import github.realtvop.aonsoku.ui.components.subPageContentPadding
import github.realtvop.aonsoku.ui.overlays.ConfirmDialog
import kotlinx.coroutines.launch

/** The ways the list of cached items narrows down, by what an item is or why it is kept. */
enum class CacheFilter(val id: String, val matches: (CachedItem) -> Boolean) {
    All("all", { true }),
    Audio("audio", { it.type == CachedItemType.Audio }),
    Cover("cover", { it.type == CachedItemType.Cover }),
    Album("album", { it.type == CachedItemType.Album }),
    Playlist("playlist", { it.type == CachedItemType.Playlist }),
    Explicit("explicit", { it.source == AudioCacheSource.Explicit }),
    Smart("smart", { it.source == AudioCacheSource.Smart }),
    Lru("lru", { it.source == AudioCacheSource.Lru }),
}

/** Every cached item by name, to look through and delete one at a time. */
@Composable
internal fun CacheManagerPage() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val scope = rememberCoroutineScope()
    val cached by graph.offline.cached.collectAsStateWithLifecycle()
    var items by remember { mutableStateOf<List<CachedItem>?>(null) }
    var filter by rememberSaveable { mutableStateOf(CacheFilter.All) }
    var deleting by remember { mutableStateOf<CachedItem?>(null) }
    var reloads by remember { mutableIntStateOf(0) }

    // Downloads that finish while the page is open show up as well.
    LaunchedEffect(cached.keys, reloads) {
        items = runSuspendCatching { graph.offline.items() }.getOrDefault(emptyList())
    }

    val title = t("settings.storage.cacheManager.group")
    val shown = remember(items, filter) { items?.filter(filter.matches) }
    val listState = rememberLazyListState()
    val collapsed by rememberTitleCollapsed(listState)

    Box(modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = subPageContentPadding(),
        ) {
            item(key = "title") { PageTitle(title = title) }
            item(key = "filters") {
                Row(
                    modifier = Modifier
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp)
                        .padding(bottom = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for (option in CacheFilter.entries) {
                        FilterChip(
                            selected = option == filter,
                            onClick = { filter = option },
                            label = { Text(t("settings.storage.cacheManager.filter.${option.id}")) },
                        )
                    }
                }
            }
            when {
                shown == null -> item(key = "loading") { PageLoading(Modifier.heightIn(min = 240.dp)) }
                shown.isEmpty() -> item(key = "empty") {
                    EmptyState(
                        icon = Icons.Rounded.Storage,
                        title = t("settings.storage.cacheManager.list.empty"),
                    )
                }
                else -> {
                    item(key = "total") {
                        Text(
                            text = strings.t(
                                "settings.storage.cacheManager.list.total",
                                "count" to shown.size,
                                "size" to formatBytes(shown.sumOf { it.sizeBytes }),
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                        )
                    }
                    items(shown, key = { it.key }, contentType = { "item" }) { item ->
                        CachedItemRow(item = item, onDelete = { deleting = item })
                    }
                }
            }
        }
        SubPageTopBar(title = title, collapsed = collapsed)
    }

    deleting?.let { item ->
        ConfirmDialog(
            title = t("settings.storage.cacheManager.confirmDelete.title"),
            description = t("settings.storage.cacheManager.confirmDelete.description", "name" to item.name),
            confirmLabel = t("settings.storage.cacheManager.list.delete"),
            cancelLabel = t("generic.cancel"),
            onDismiss = { deleting = null },
            onConfirm = {
                deleting = null
                scope.launch {
                    runSuspendCatching { graph.offline.remove(item) }
                    reloads++
                }
            },
        )
    }
}

@Composable
private fun CachedItemRow(item: CachedItem, onDelete: () -> Unit) {
    val strings = LocalStrings.current
    val details = buildList {
        add(t("settings.storage.cacheManager.list.type_${item.type.id}"))
        item.source?.let { add(t("settings.storage.cacheManager.filter.${it.id}")) }
        if (item.sizeBytes > 0) add(formatBytes(item.sizeBytes))
        add(strings.fromNow(item.cachedAt))
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .padding(start = 20.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f).padding(vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (item.removedFromServer) {
                    Icon(
                        Icons.Rounded.WarningAmber,
                        contentDescription = t("settings.storage.cacheManager.list.removedFromServer"),
                        tint = StatusColors.Caution,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    text = item.name,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            item.subtitle?.let { subtitle ->
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = details.joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Rounded.Delete,
                contentDescription = "${t("settings.storage.cacheManager.list.delete")}: ${item.name}",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
