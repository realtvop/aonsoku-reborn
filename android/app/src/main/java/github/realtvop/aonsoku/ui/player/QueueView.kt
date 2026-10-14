package github.realtvop.aonsoku.ui.player

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.player.RepeatMode
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.ui.components.CachedIndicator
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.ReorderState
import github.realtvop.aonsoku.ui.components.queueSongCoverArt
import github.realtvop.aonsoku.ui.components.rememberReorderState
import github.realtvop.aonsoku.ui.components.reorderHandle
import github.realtvop.aonsoku.ui.components.reorderItem
import github.realtvop.aonsoku.ui.components.songCoverArt
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs

// Minimum heights of the rows. They add up to the space the queue takes below
// the current song, and what is missing to a full viewport is appended, so the
// current song can always be scrolled to the top with the history above it.
private val QueueRowHeight = 64.dp
private val SectionHeaderHeight = 36.dp
private val ModeButtonsHeight = 48.dp
private val SourceLabelHeight = 20.dp
private val EmptyMessageHeight = 52.dp
private val IndicatorHeight = 32.dp
private val QueueBottomPadding = 16.dp

/** Rows are inset from the screen edge and their content from the row. */
private val RowInset = PlayerRowInset
private val RowContentInset = PlayerRowContentInset

/** Peeking at up to this many history rows springs back to the current song. */
private const val HISTORY_PEEK_ROWS = 3

/** How long a dropped order is shown while the engine has not confirmed it. */
private const val DROP_CONFIRMATION_MS = 1_500L

private const val USER_SECTION = "user:"
private const val CONTEXT_SECTION = "context:"

/** A queue row: [index] is its position in the engine's list, [key] its identity while shown. */
private data class QueueEntry(val key: String, val song: QueueSong, val index: Int)

/** Keys stay unique when a song is queued more than once. */
private fun queueEntries(section: String, songs: List<QueueSong>, offset: Int): List<QueueEntry> {
    val seen = HashMap<String, Int>()
    return songs.mapIndexed { position, song ->
        val occurrence = (seen[song.id] ?: 0) + 1
        seen[song.id] = occurrence
        QueueEntry("$section${song.id}#$occurrence", song, offset + position)
    }
}

private fun sectionOf(key: Any): String? = when {
    key !is String -> null
    key.startsWith(USER_SECTION) -> USER_SECTION
    key.startsWith(CONTEXT_SECTION) -> CONTEXT_SECTION
    else -> null
}

/**
 * Where the song with [id] is now, looking from [start] and preferring the
 * position closest to [expected]. An options sheet outlives the row it was
 * opened from, and the queue moves on in the meantime.
 */
private fun List<QueueSong>.indexNear(expected: Int, id: String, start: Int): Int? =
    indices.filter { it >= start && this[it].id == id }.minByOrNull { abs(it - expected) }

private fun List<QueueEntry>.moved(from: Any, to: Any): List<QueueEntry> {
    val source = indexOfFirst { it.key == from }
    val target = indexOfFirst { it.key == to }
    if (source < 0 || target < 0) return this
    return toMutableList().apply { add(target, removeAt(source)) }
}

/**
 * The queue tab: play history (hidden above until scrolled to), the current
 * song, the shuffle and repeat buttons, the manually queued songs, and what
 * continues from the album or playlist. Rows of the last two can be reordered.
 */
@Composable
fun QueueView(state: PlayerState, onShowPlaying: () -> Unit, modifier: Modifier = Modifier) {
    val graph = LocalAppGraph.current
    val player = graph.player
    val overlays = LocalOverlays.current
    val palette = LocalPlayerPalette.current
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val hapticsEnabled by rememberUpdatedState(settings.hapticFeedback)

    val current = state.current
    if (current == null) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                text = t("fullscreen.emptyQueue"),
                style = MaterialTheme.typography.bodyMedium,
                color = palette.muted,
            )
        }
        return
    }

    val historyVersion by player.historyVersion.collectAsStateWithLifecycle()
    val storedHistory by produceState(emptyList<Song>(), historyVersion) {
        value = player.playHistory()
    }
    // Oldest first, so the song played last sits right above the current one.
    val history = remember(storedHistory, current.id) {
        val past = if (storedHistory.firstOrNull()?.id == current.id) {
            storedHistory.drop(1)
        } else {
            storedHistory
        }
        past.asReversed()
    }

    val userOffset = if (state.isInUserQueue) 1 else 0
    val contextOffset = state.contextIndex + 1
    val userEntries = remember(state.userQueue, state.isInUserQueue) {
        queueEntries(USER_SECTION, state.upcomingUserQueue, userOffset)
    }
    val contextEntries = remember(state.contextSongs, state.contextIndex) {
        queueEntries(CONTEXT_SECTION, state.upcomingContext, contextOffset)
    }
    // While a row is dragged, and until the engine reports the new order, the
    // list shows the order the drop produces.
    var userOrder by remember { mutableStateOf<List<QueueEntry>?>(null) }
    var contextOrder by remember { mutableStateOf<List<QueueEntry>?>(null) }
    LaunchedEffect(userEntries) { userOrder = null }
    LaunchedEffect(contextEntries) { contextOrder = null }
    val userShown = userOrder ?: userEntries
    val contextShown = contextOrder ?: contextEntries

    // Index of the current song: the history and its header come first.
    val currentIndex = if (history.isEmpty()) 0 else history.size + 1
    val latestCurrentIndex by rememberUpdatedState(currentIndex)
    // Not saved: the queue always opens at the current song.
    val listState = remember { LazyListState() }

    // A lazy list follows its first row by key, but only looks for that key
    // near the old position. A history that loads, or is cleared, moves the
    // rows further than that, so the position is carried over here.
    val anchor = remember { intArrayOf(currentIndex) }
    SideEffect {
        val previous = anchor[0]
        if (previous == currentIndex) return@SideEffect
        anchor[0] = currentIndex
        val shift = currentIndex - previous
        if (abs(shift) <= 1) return@SideEffect
        val first = listState.firstVisibleItemIndex
        if (first >= previous) {
            listState.requestScrollToItem(first + shift, listState.firstVisibleItemScrollOffset)
        } else {
            listState.requestScrollToItem(currentIndex)
        }
    }

    val reorder = rememberReorderState(
        listState = listState,
        // Songs of a controlled device's queue stay where they are, as on the web.
        canMove = { from, to ->
            !state.isRemote && sectionOf(from) != null && sectionOf(from) == sectionOf(to)
        },
        onMove = { from, to ->
            when (sectionOf(from)) {
                USER_SECTION -> userOrder = userShown.moved(from, to)
                CONTEXT_SECTION -> contextOrder = contextShown.moved(from, to)
            }
        },
        onDrop = { key ->
            if (hapticsEnabled) haptics.performHapticFeedback(HapticFeedbackType.GestureEnd)
            when (sectionOf(key)) {
                USER_SECTION -> {
                    val order = userOrder
                    val position = order?.indexOfFirst { it.key == key } ?: -1
                    val entry = order?.getOrNull(position)
                    if (entry == null || entry.index == userOffset + position) {
                        userOrder = null
                    } else {
                        player.reorderUserQueue(entry.index, userOffset + position)
                        scope.launch {
                            delay(DROP_CONFIRMATION_MS)
                            if (userOrder === order) userOrder = null
                        }
                    }
                }
                CONTEXT_SECTION -> {
                    val order = contextOrder
                    val position = order?.indexOfFirst { it.key == key } ?: -1
                    val entry = order?.getOrNull(position)
                    if (entry == null || entry.index == contextOffset + position) {
                        contextOrder = null
                    } else {
                        player.reorderContext(entry.index, contextOffset + position)
                        scope.launch {
                            delay(DROP_CONFIRMATION_MS)
                            if (contextOrder === order) contextOrder = null
                        }
                    }
                }
            }
        },
        onLift = {
            if (hapticsEnabled) {
                haptics.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate)
            }
        },
    )

    // Peeking at the newest history rows springs back; scrolling further, or
    // to the very top, stays there.
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (scrolling || reorder.draggingKey != null) return@collect
            val target = latestCurrentIndex
            val first = listState.firstVisibleItemIndex
            if (target == 0 || first >= target) return@collect
            if (first == 0 && listState.firstVisibleItemScrollOffset == 0) return@collect
            if (target - maxOf(first, 1) in 1..HISTORY_PEEK_ROWS) {
                if (hapticsEnabled) haptics.performHapticFeedback(HapticFeedbackType.GestureEnd)
                try {
                    listState.animateScrollToItem(target)
                } catch (interrupted: CancellationException) {
                    // A touch took over the scroll; only stop when this effect ended.
                    currentCoroutineContext().ensureActive()
                }
            }
        }
    }
    // Playing a row makes it the current song, which is shown at the top.
    val playAndShow: (() -> Unit) -> Unit = { play ->
        play()
        scope.launch { listState.animateScrollToItem(latestCurrentIndex) }
    }
    val showMenu: (Overlay) -> Unit = { overlay ->
        if (hapticsEnabled) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        overlays.show(overlay)
    }

    val showEmpty = userShown.isEmpty() && contextShown.isEmpty()
    val repeating = state.repeat != RepeatMode.Off
    val sourceName = state.sourceName?.takeIf { it.isNotBlank() }

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        var below = CurrentSongRowHeight + ModeButtonsHeight + QueueBottomPadding
        if (userShown.isNotEmpty()) below += SectionHeaderHeight + QueueRowHeight * userShown.size
        if (contextShown.isNotEmpty()) {
            below += SectionHeaderHeight + QueueRowHeight * contextShown.size
            if (sourceName != null) below += SourceLabelHeight
        }
        if (showEmpty) below += EmptyMessageHeight
        if (repeating) below += IndicatorHeight
        if (state.shuffle) below += IndicatorHeight
        val tail = (maxHeight - below).coerceAtLeast(0.dp)

        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = QueueBottomPadding),
        ) {
            if (history.isNotEmpty()) {
                item(key = "history-header", contentType = "header") {
                    QueueSectionHeader(
                        title = t("fullscreen.queueHistory"),
                        onClear = { scope.launch { player.clearPlayHistory() } },
                    )
                }
                itemsIndexed(
                    items = history,
                    key = { index, song -> "history:$index:${song.id}" },
                    contentType = { _, _ -> "row" },
                ) { _, song ->
                    QueueRow(
                        title = song.title,
                        artist = song.artistLabel,
                        art = songCoverArt(song),
                        onClick = { playAndShow { player.playNow(song) } },
                        onLongClick = { showMenu(Overlay.SongMenu(song)) },
                        songId = song.id,
                    )
                }
            }

            item(key = "current", contentType = "current") {
                CurrentSongRow(state = state, song = current, onClick = onShowPlaying)
            }
            item(key = "modes", contentType = "modes") { QueueModeButtons(state) }

            if (userShown.isNotEmpty()) {
                item(key = "user-header", contentType = "header") {
                    QueueSectionHeader(
                        title = t("fullscreen.queue"),
                        onClear = player::clearUserQueue,
                    )
                }
                items(userShown, key = { it.key }, contentType = { "row" }) { entry ->
                    ReorderableQueueRow(
                        entry = entry,
                        reorder = reorder,
                        movable = !state.isRemote,
                        onClick = { playAndShow { player.playFromUserQueue(entry.index) } },
                        onLongClick = {
                            showMenu(
                                Overlay.SongMenu(
                                    song = player.songFor(entry.song),
                                    queueRemove = if (state.isRemote) null else ({
                                        val now = player.state.value
                                        now.userQueue
                                            .indexNear(
                                                expected = entry.index,
                                                id = entry.song.id,
                                                start = if (now.isInUserQueue) 1 else 0,
                                            )
                                            ?.let(player::removeFromUserQueue)
                                    }),
                                ),
                            )
                        },
                    )
                }
            }

            if (contextShown.isNotEmpty()) {
                item(key = "context-header", contentType = "context-header") {
                    Column {
                        QueueSectionHeader(title = t("fullscreen.queueContinue"))
                        if (sourceName != null) {
                            Text(
                                text = t("fullscreen.queueFromSource", "source" to sourceName),
                                style = MaterialTheme.typography.labelMedium,
                                color = palette.faint,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier
                                    .heightIn(min = SourceLabelHeight)
                                    .padding(horizontal = RowInset + RowContentInset),
                            )
                        }
                    }
                }
                items(contextShown, key = { it.key }, contentType = { "row" }) { entry ->
                    ReorderableQueueRow(
                        entry = entry,
                        reorder = reorder,
                        movable = !state.isRemote,
                        onClick = { playAndShow { player.playFromContext(entry.index) } },
                        onLongClick = {
                            showMenu(
                                Overlay.SongMenu(
                                    song = player.songFor(entry.song),
                                    queueRemove = if (state.isRemote) null else ({
                                        val now = player.state.value
                                        now.contextSongs
                                            .indexNear(
                                                expected = entry.index,
                                                id = entry.song.id,
                                                start = now.contextIndex + 1,
                                            )
                                            ?.let(player::removeFromContext)
                                    }),
                                ),
                            )
                        },
                    )
                }
            }

            if (showEmpty) {
                item(key = "empty", contentType = "empty") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = EmptyMessageHeight),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = t("fullscreen.emptyQueue"),
                            style = MaterialTheme.typography.labelMedium,
                            color = palette.faint,
                        )
                    }
                }
            }
            if (repeating) {
                item(key = "repeating", contentType = "indicator") {
                    QueueIndicator(
                        icon = if (state.repeat == RepeatMode.One) {
                            Icons.Rounded.RepeatOne
                        } else {
                            Icons.Rounded.Repeat
                        },
                        label = t("fullscreen.queueRepeating"),
                    )
                }
            }
            if (state.shuffle) {
                item(key = "shuffling", contentType = "indicator") {
                    QueueIndicator(
                        icon = Icons.Rounded.Shuffle,
                        label = t("fullscreen.queueShuffling"),
                    )
                }
            }
            item(key = "tail", contentType = "tail") { Spacer(Modifier.height(tail)) }
        }
    }
}

@Composable
private fun LazyItemScope.ReorderableQueueRow(
    entry: QueueEntry,
    reorder: ReorderState,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    movable: Boolean = true,
) {
    QueueRow(
        title = entry.song.title,
        artist = entry.song.artist,
        art = queueSongCoverArt(entry.song),
        onClick = onClick,
        onLongClick = onLongClick,
        songId = entry.song.id,
        modifier = Modifier.reorderItem(this, reorder, entry.key),
        lifted = reorder.isLifted(entry.key),
        handle = if (!movable) null else ({
            Box(
                modifier = Modifier
                    .size(width = 48.dp, height = QueueRowHeight)
                    .reorderHandle(reorder, entry.key),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Rounded.DragHandle,
                    contentDescription = null,
                    tint = LocalPlayerPalette.current.content.copy(alpha = 0.35f),
                    modifier = Modifier.size(22.dp),
                )
            }
        }),
    )
}

/**
 * Artwork, title, and artist of a queued song; tap plays it, long press opens
 * its options. A [lifted] row is opaque and raised above the rows it passes.
 */
@Composable
private fun QueueRow(
    title: String,
    artist: String,
    art: CoverArt,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    songId: String,
    modifier: Modifier = Modifier,
    lifted: Boolean = false,
    handle: (@Composable () -> Unit)? = null,
) {
    val palette = LocalPlayerPalette.current
    val backdrop = LocalPlayerBackdrop.current
    val elevation by animateDpAsState(if (lifted) 8.dp else 0.dp, label = "queueRowElevation")
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = RowInset)
            .shadow(elevation, MaterialTheme.shapes.medium, clip = true)
            .drawBehind {
                if (lifted) {
                    drawRect(backdrop.value)
                    drawRect(palette.container)
                }
            }
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .heightIn(min = QueueRowHeight)
            .padding(
                start = RowContentInset,
                end = if (handle == null) RowContentInset else 0.dp,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoverImage(
            art = art,
            modifier = Modifier.size(40.dp),
            kind = CoverKind.Song,
            shape = MaterialTheme.shapes.extraSmall,
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (artist.isNotEmpty()) {
                Text(
                    text = artist,
                    style = MaterialTheme.typography.bodySmall,
                    color = palette.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        CachedIndicator(
            songId = songId,
            modifier = Modifier.padding(start = 8.dp),
            tint = palette.muted,
        )
        handle?.invoke()
    }
}

/** Shuffle and repeat as labeled buttons that say what a tap does. */
@Composable
private fun QueueModeButtons(state: PlayerState) {
    val player = LocalAppGraph.current.player
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = ModeButtonsHeight),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PlayerPill(
            icon = Icons.Rounded.Shuffle,
            label = t(shuffleActionKey(state.shuffle)),
            active = state.shuffle,
            enabled = !state.isPlayingOneSong && state.hasNext,
            onClick = player::toggleShuffle,
        )
        PlayerPill(
            icon = if (state.repeat == RepeatMode.One) {
                Icons.Rounded.RepeatOne
            } else {
                Icons.Rounded.Repeat
            },
            label = t(repeatActionKey(state.repeat)),
            active = state.repeat != RepeatMode.Off,
            onClick = player::cycleRepeat,
        )
    }
}

@Composable
private fun QueueSectionHeader(title: String, onClear: (() -> Unit)? = null) {
    val palette = LocalPlayerPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = SectionHeaderHeight)
            .padding(start = RowInset + RowContentInset, end = RowInset),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title.uppercase(),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.8.sp,
            color = palette.muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (onClear != null) {
            TextButton(
                onClick = onClear,
                modifier = Modifier.height(SectionHeaderHeight),
                colors = ButtonDefaults.textButtonColors(contentColor = palette.faint),
                contentPadding = PaddingValues(horizontal = RowContentInset),
            ) {
                Text(text = t("generic.clear"), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

/** Note below the queue saying that it repeats or is shuffled. */
@Composable
private fun QueueIndicator(icon: ImageVector, label: String) {
    val tint = LocalPlayerPalette.current.content.copy(alpha = 0.3f)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = IndicatorHeight),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Text(
            text = label.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            letterSpacing = 1.6.sp,
            color = tint,
        )
    }
}
