package github.realtvop.aonsoku.ui.player

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.theme.LocalSystemBarsOverride
import github.realtvop.aonsoku.ui.components.queueSongCoverArt
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch

/** What the full-screen player shows between its header and its tab buttons. */
enum class PlayerTab { Playing, Queue }

/** Whether the full-screen player is open, and on which tab. */
@Stable
class FullscreenPlayerState(isOpen: Boolean = false, tab: PlayerTab = PlayerTab.Playing) {
    var isOpen by mutableStateOf(isOpen)
        private set

    var tab by mutableStateOf(tab)
        private set

    fun open(tab: PlayerTab = PlayerTab.Playing) {
        this.tab = tab
        isOpen = true
    }

    fun close() {
        isOpen = false
    }

    fun show(tab: PlayerTab) {
        this.tab = tab
    }

    /** Shows [target], or returns to the playing view when it is already shown. */
    fun toggle(target: PlayerTab) {
        tab = if (tab == target) PlayerTab.Playing else target
    }

    companion object {
        val Saver: Saver<FullscreenPlayerState, Any> = listSaver(
            save = { listOf(it.isOpen, it.tab.name) },
            restore = { saved ->
                FullscreenPlayerState(
                    isOpen = saved[0] as Boolean,
                    tab = PlayerTab.entries.firstOrNull { it.name == saved[1] }
                        ?: PlayerTab.Playing,
                )
            },
        )
    }
}

@Composable
fun rememberFullscreenPlayerState(): FullscreenPlayerState =
    rememberSaveable(saver = FullscreenPlayerState.Saver) { FullscreenPlayerState() }

private val ContentMaxWidth = 560.dp
private val MovingShape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
private val NoArtwork = CoverArt(emptyList())

/** Position of the sheet as a fraction of its height: 0 is open, 1 is below the screen. */
private const val OPEN = 0f
private const val CLOSED = 1f

/** A drag released past this fraction, or faster than the fling speed, closes the player. */
private const val CLOSE_FRACTION = 0.25f
private val CloseFlingSpeed = 600.dp
private const val SCRIM_ALPHA = 0.32f

/** The bars follow the player once it covers more than half of the screen. */
private const val BARS_FRACTION = 0.5f

/** Half a pixel on a tall screen; the default would end the slide with a visible jump. */
private const val SHEET_THRESHOLD = 0.0005f

private val SheetSpring = spring(
    dampingRatio = Spring.DampingRatioNoBouncy,
    stiffness = Spring.StiffnessMediumLow,
    visibilityThreshold = SHEET_THRESHOLD,
)

/**
 * The player as a sheet over the whole shell: it rises from the mini player,
 * follows a downward drag, and closes on back or once nothing is loaded. Its
 * backdrop is the theme background tinted with the artwork of the song.
 */
@Composable
fun FullscreenPlayer(
    playerState: PlayerState,
    sheet: FullscreenPlayerState,
    modifier: Modifier = Modifier,
) {
    val settings by LocalAppGraph.current.settings.state.collectAsStateWithLifecycle()
    val shown = sheet.isOpen && playerState.hasMedia
    LaunchedEffect(playerState.connected, playerState.hasMedia) {
        // Nothing is loaded: starting something later must not reopen the player.
        if (playerState.connected && !playerState.hasMedia) sheet.close()
    }

    // Kept for the way out, after the queue was cleared with the player open.
    var lastLoaded by remember { mutableStateOf(playerState) }
    SideEffect { if (playerState.hasMedia) lastLoaded = playerState }
    val state = if (playerState.hasMedia) playerState else lastLoaded

    // Worked out while the player is closed too, so that it opens in its colors.
    val song = state.current?.takeIf { !state.isRadio }
    val songColor = rememberArtworkColor(if (song != null) queueSongCoverArt(song) else NoArtwork)
    val backdropColor = rememberBackdropColor(songColor, settings.songColorIntensity)

    val offset = remember { Animatable(if (shown) OPEN else CLOSED, SHEET_THRESHOLD) }
    LaunchedEffect(shown) { offset.animateTo(if (shown) OPEN else CLOSED, SheetSpring) }
    val offscreen by remember { derivedStateOf { offset.value >= CLOSED } }
    if (!shown && offscreen) return

    val scope = rememberCoroutineScope()
    val backdrop = animateColorAsState(
        targetValue = backdropColor,
        animationSpec = MaterialTheme.motionScheme.slowEffectsSpec<Color>(),
        label = "playerBackdrop",
    )
    val palette = rememberPlayerPalette(backdropColor)
    val tab = if (state.isRadio) PlayerTab.Playing else sheet.tab
    var height by remember { mutableIntStateOf(0) }
    val closeFlingSpeed = with(LocalDensity.current) { CloseFlingSpeed.toPx() }

    BackHandler(enabled = shown) {
        if (tab != PlayerTab.Playing) sheet.show(PlayerTab.Playing) else sheet.close()
    }

    // The status bar icons have to be readable on the backdrop, not on the theme.
    val bars = LocalSystemBarsOverride.current
    val coversBars by remember { derivedStateOf { offset.value < BARS_FRACTION } }
    DisposableEffect(bars, coversBars, palette.isDark) {
        if (coversBars) bars.value = palette.isDark
        onDispose { bars.value = null }
    }

    val dragState = rememberDraggableState { delta ->
        if (height > 0) {
            // Undispatched: the sheet has to follow the finger in the same frame.
            scope.launch(start = CoroutineStart.UNDISPATCHED) {
                offset.snapTo((offset.value + delta / height).coerceIn(OPEN, CLOSED))
            }
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .drawBehind {
                    drawRect(Color.Black, alpha = SCRIM_ALPHA * (CLOSED - offset.value))
                },
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .onSizeChanged { height = it.height }
                .graphicsLayer {
                    translationY = offset.value * size.height
                    shape = if (offset.value > OPEN) MovingShape else RectangleShape
                    clip = true
                }
                .draggable(
                    state = dragState,
                    orientation = Orientation.Vertical,
                    onDragStopped = { velocity ->
                        val close = !shown || velocity > closeFlingSpeed ||
                            (offset.value > CLOSE_FRACTION && velocity >= 0f)
                        offset.animateTo(
                            targetValue = if (close) CLOSED else OPEN,
                            animationSpec = SheetSpring,
                            initialVelocity = if (height > 0) velocity / height else 0f,
                        )
                        if (close) sheet.close()
                    },
                )
                .drawBehind { drawRect(backdrop.value) },
        ) {
            CompositionLocalProvider(
                LocalPlayerBackdrop provides backdrop,
                LocalPlayerPalette provides palette,
                LocalContentColor provides palette.content,
            ) {
                Column(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .safeDrawingPadding()
                        .widthIn(max = ContentMaxWidth)
                        .fillMaxHeight(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    PlayerHeader(onClose = sheet::close)
                    val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
                    AnimatedContent(
                        targetState = tab,
                        transitionSpec = { fadeIn(effects) togetherWith fadeOut(effects) },
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth(),
                        label = "playerTab",
                    ) { current ->
                        when (current) {
                            PlayerTab.Playing -> PlayingView(state)
                            PlayerTab.Queue -> QueueView(
                                state = state,
                                onShowPlaying = { sheet.show(PlayerTab.Playing) },
                            )
                        }
                    }
                    // A radio stream has neither a queue nor lyrics.
                    if (!state.isRadio) PlayerTabs(tab = tab, onToggle = sheet::toggle)
                }
            }
        }
    }
}

/** Close on the left, the drag handle in the middle, and the color settings on the right. */
@Composable
private fun PlayerHeader(onClose: () -> Unit) {
    val overlays = LocalOverlays.current
    val palette = LocalPlayerPalette.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(width = 36.dp, height = 4.dp)
                .clip(CircleShape)
                .background(palette.content.copy(alpha = 0.4f)),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PlayerIconButton(
                icon = Icons.Rounded.KeyboardArrowDown,
                description = t("fullscreen.close"),
                onClick = onClose,
                iconSize = 28.dp,
            )
            PlayerIconButton(
                icon = Icons.Rounded.Tune,
                description = t("settings.label"),
                onClick = { overlays.show(Overlay.PlayerColors) },
            )
        }
    }
}

/** Switches between the tabs; the selected one returns to the playing view. */
@Composable
private fun PlayerTabs(tab: PlayerTab, onToggle: (PlayerTab) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth(0.75f)
            .padding(top = 8.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Lyrics are not available in the native player yet.
        PlayerTabButton(
            icon = Icons.Rounded.Lyrics,
            label = t("fullscreen.lyrics"),
            selected = false,
            enabled = false,
            onClick = {},
        )
        PlayerTabButton(
            icon = Icons.AutoMirrored.Rounded.QueueMusic,
            label = t("fullscreen.queue"),
            selected = tab == PlayerTab.Queue,
            onClick = { onToggle(PlayerTab.Queue) },
        )
    }
}

@Composable
private fun PlayerTabButton(
    icon: ImageVector,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    val palette = LocalPlayerPalette.current
    IconButton(
        onClick = onClick,
        modifier = Modifier.semantics { this.selected = selected },
        enabled = enabled,
        colors = IconButtonDefaults.iconButtonColors(
            containerColor = if (selected) palette.container else Color.Transparent,
            contentColor = if (selected) palette.content else palette.muted,
            disabledContentColor = palette.content.copy(alpha = 0.3f),
        ),
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(22.dp))
    }
}
