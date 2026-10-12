package github.realtvop.aonsoku.ui.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.EmptyState
import github.realtvop.aonsoku.ui.components.NowPlayingBars
import github.realtvop.aonsoku.ui.components.PageLoading
import github.realtvop.aonsoku.ui.components.PageTitle
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.rememberTitleCollapsed
import github.realtvop.aonsoku.ui.components.subPageContentPadding
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

class RadiosViewModel(private val graph: AppGraph) : ViewModel() {
    private val _radios = MutableStateFlow<List<Radio>?>(null)

    /** Null while the first load is running. Radios are not available offline. */
    val radios: StateFlow<List<Radio>?> = _radios.asStateFlow()

    init {
        load()
        viewModelScope.launch {
            graph.library.changes.collect { if (it == LibraryChange.Radios) load() }
        }
        viewModelScope.launch {
            graph.network.isOnline.drop(1).collect { online -> if (online) load() }
        }
    }

    private fun load() {
        viewModelScope.launch {
            val loaded = runCatching { graph.library.radios() }.getOrNull()
            _radios.value = loaded ?: _radios.value ?: emptyList()
        }
    }
}

@Composable
fun RadiosScreen() {
    val model = graphViewModel { RadiosViewModel(it) }
    val radios by model.radios.collectAsStateWithLifecycle()
    val graph = LocalAppGraph.current
    val overlays = LocalOverlays.current
    val playerState by graph.player.state.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val collapsed by rememberTitleCollapsed(listState)
    val title = t("sidebar.radios")
    val addRadio = { overlays.show(Overlay.RadioForm()) }

    Box(modifier = Modifier.fillMaxSize()) {
        val list = radios
        when {
            list == null -> PageLoading()
            list.isEmpty() -> EmptyState(
                title = t("radios.empty.title"),
                description = t("radios.empty.info"),
                icon = Icons.Rounded.Radio,
                modifier = Modifier.fillMaxSize(),
                action = {
                    Button(onClick = addRadio) {
                        Icon(Icons.Rounded.Add, contentDescription = null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(t("radios.addRadio"))
                    }
                },
            )
            else -> LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = subPageContentPadding(),
            ) {
                item(key = "title") {
                    PageTitle(title = title, count = list.size.toString()) {
                        IconButton(onClick = addRadio) {
                            Icon(Icons.Rounded.Add, contentDescription = t("radios.addRadio"))
                        }
                    }
                }
                itemsIndexed(list, key = { _, radio -> radio.id }) { index, radio ->
                    val isCurrent = playerState.isRadio && playerState.radio?.id == radio.id
                    RadioRow(
                        radio = radio,
                        isCurrent = isCurrent,
                        isPlaying = isCurrent && playerState.isPlaying,
                        onClick = {
                            if (isCurrent) {
                                graph.player.togglePlayPause()
                            } else {
                                graph.player.playRadio(list, index)
                            }
                        },
                        onMore = { overlays.show(Overlay.RadioMenu(radio)) },
                    )
                }
            }
        }
        SubPageTopBar(title = title, collapsed = collapsed || radios.isNullOrEmpty())
    }
}

@Composable
private fun RadioRow(
    radio: Radio,
    isCurrent: Boolean,
    isPlaying: Boolean,
    onClick: () -> Unit,
    onMore: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .height(64.dp)
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(MaterialTheme.shapes.medium)
                .background(
                    if (isCurrent) {
                        MaterialTheme.colorScheme.primaryContainer
                    } else {
                        MaterialTheme.colorScheme.surfaceContainerHighest
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (isCurrent) {
                NowPlayingBars(animate = isPlaying, modifier = Modifier.size(18.dp))
            } else {
                Icon(Icons.Rounded.Radio, contentDescription = null, Modifier.size(22.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = radio.name,
                style = MaterialTheme.typography.bodyLarge,
                color = if (isCurrent) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = radio.homePageUrl?.takeIf { it.isNotBlank() } ?: radio.streamUrl,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onMore) {
            Icon(
                Icons.Rounded.MoreVert,
                contentDescription = t("playlist.buttons.options", "name" to radio.name),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
