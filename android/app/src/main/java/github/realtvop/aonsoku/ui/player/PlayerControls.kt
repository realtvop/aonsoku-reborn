package github.realtvop.aonsoku.ui.player

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeDown
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.player.RepeatMode
import github.realtvop.aonsoku.ui.components.formatClock
import kotlin.math.roundToInt

/** Horizontal room the slider keeps at both ends for its thumb. */
val PlayerSliderInset = 10.dp

private val PlayerSliderHeight = 36.dp
private const val DISABLED_ALPHA = 0.38f

/**
 * Slider in the player palette: a thin track with an optional secondary
 * (buffered) range, set by tapping or dragging anywhere along it.
 * [onValueChange] follows the finger; [onValueChangeFinished] commits.
 */
@Composable
fun PlayerSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: (Float) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    secondaryValue: Float? = null,
    enabled: Boolean = true,
    valueText: ((Float) -> String)? = null,
) {
    val palette = LocalPlayerPalette.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    var dragValue by remember { mutableStateOf<Float?>(null) }
    val shown = (dragValue ?: value).coerceIn(valueRange)
    val dragging = dragValue != null
    val range by rememberUpdatedState(valueRange)
    val change by rememberUpdatedState(onValueChange)
    val finish by rememberUpdatedState(onValueChangeFinished)
    val trackHeight by animateDpAsState(if (dragging) 8.dp else 4.dp, label = "sliderTrack")
    val thumbRadius by animateDpAsState(if (dragging) 9.dp else 6.dp, label = "sliderThumb")

    fun valueAt(x: Float, width: Int, insetPx: Float): Float {
        val span = (width - insetPx * 2).coerceAtLeast(1f)
        val along = ((x - insetPx) / span).coerceIn(0f, 1f)
        val fraction = if (rtl) 1f - along else along
        return range.start + fraction * (range.endInclusive - range.start)
    }

    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(PlayerSliderHeight)
            .semantics(mergeDescendants = true) {
                contentDescription = label
                progressBarRangeInfo = ProgressBarRangeInfo(shown, valueRange)
                if (valueText != null) stateDescription = valueText(shown)
                if (!enabled) disabled()
                setProgress { target ->
                    if (!enabled) return@setProgress false
                    val coerced = target.coerceIn(valueRange)
                    onValueChange(coerced)
                    onValueChangeFinished(coerced)
                    true
                }
            }
            .pointerInput(enabled, rtl) {
                if (!enabled) return@pointerInput
                detectTapGestures { position ->
                    val target = valueAt(position.x, size.width, PlayerSliderInset.toPx())
                    change(target)
                    finish(target)
                }
            }
            .pointerInput(enabled, rtl) {
                if (!enabled) return@pointerInput
                detectHorizontalDragGestures(
                    onDragStart = { position ->
                        val target = valueAt(position.x, size.width, PlayerSliderInset.toPx())
                        dragValue = target
                        change(target)
                    },
                    onDragEnd = {
                        dragValue?.let { finish(it) }
                        dragValue = null
                    },
                    onDragCancel = { dragValue = null },
                ) { pointer, _ ->
                    pointer.consume()
                    val target = valueAt(pointer.position.x, size.width, PlayerSliderInset.toPx())
                    dragValue = target
                    change(target)
                }
            },
    ) {
        val inset = PlayerSliderInset.toPx()
        val start = inset
        val end = size.width - inset
        val centerY = size.height / 2f
        val span = valueRange.endInclusive - valueRange.start
        val alpha = if (enabled) 1f else DISABLED_ALPHA

        fun x(target: Float): Float {
            val fraction = if (span > 0f) ((target - valueRange.start) / span).coerceIn(0f, 1f) else 0f
            return if (rtl) end - fraction * (end - start) else start + fraction * (end - start)
        }

        val stroke = trackHeight.toPx()
        val origin = Offset(x(valueRange.start), centerY)
        drawLine(
            color = palette.sliderTrack,
            start = Offset(start, centerY),
            end = Offset(end, centerY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
            alpha = alpha,
        )
        if (secondaryValue != null && secondaryValue > valueRange.start) {
            drawLine(
                color = palette.sliderTrack,
                start = origin,
                end = Offset(x(secondaryValue), centerY),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
                alpha = alpha,
            )
        }
        if (enabled) {
            val thumb = Offset(x(shown), centerY)
            drawLine(
                color = palette.sliderRange,
                start = origin,
                end = thumb,
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
            drawCircle(color = palette.sliderRange, radius = thumbRadius.toPx(), center = thumb)
        }
    }
}

/** Seek bar with the elapsed time and the duration below it. */
@Composable
fun PlayerProgress(modifier: Modifier = Modifier) {
    val player = LocalAppGraph.current.player
    val palette = LocalPlayerPalette.current
    val progress by player.progress.collectAsStateWithLifecycle()
    var seeking by remember { mutableStateOf<Float?>(null) }
    val duration = progress.duration.toFloat()
    val hasDuration = duration > 0f
    val position = seeking
        ?: progress.position.toFloat().coerceIn(0f, if (hasDuration) duration else 0f)

    Column(modifier = modifier.fillMaxWidth()) {
        PlayerSlider(
            value = position,
            onValueChange = { seeking = it },
            onValueChangeFinished = {
                player.seek(it.toDouble())
                seeking = null
            },
            label = t("player.tooltips.progress"),
            valueRange = 0f..(if (hasDuration) duration else 1f),
            secondaryValue = progress.buffered.toFloat().takeIf { hasDuration },
            enabled = hasDuration,
            valueText = { formatClock(it.toInt()) },
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = PlayerSliderInset),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            val style = MaterialTheme.typography.labelSmall.merge(
                TextStyle(fontFeatureSettings = "tnum"),
            )
            Text(text = formatClock(position.toInt()), style = style, color = palette.faint)
            Text(text = formatClock(duration.toInt()), style = style, color = palette.faint)
        }
    }
}

/** Shuffle, previous, play/pause, next, and repeat. */
@Composable
fun TransportControls(state: PlayerState, modifier: Modifier = Modifier) {
    val player = LocalAppGraph.current.player
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ModeToggle(
            icon = Icons.Rounded.Shuffle,
            active = state.shuffle,
            description = t(shuffleActionKey(state.shuffle)),
            enabled = !state.isPlayingOneSong && state.hasNext,
            onClick = player::toggleShuffle,
        )
        PlayerIconButton(
            icon = Icons.Rounded.SkipPrevious,
            description = t("player.tooltips.previous"),
            onClick = player::previous,
            enabled = state.current != null && !state.isRadio,
            iconSize = 34.dp,
        )
        PlayPauseButton(state = state, onClick = player::togglePlayPause)
        PlayerIconButton(
            icon = Icons.Rounded.SkipNext,
            description = t("player.tooltips.next"),
            onClick = player::next,
            enabled = state.hasNext,
            iconSize = 34.dp,
        )
        ModeToggle(
            icon = if (state.repeat == RepeatMode.One) {
                Icons.Rounded.RepeatOne
            } else {
                Icons.Rounded.Repeat
            },
            active = state.repeat != RepeatMode.Off,
            description = t(repeatActionKey(state.repeat)),
            enabled = !state.isRadio,
            onClick = player::cycleRepeat,
        )
    }
}

/** What tapping the shuffle control does next. */
fun shuffleActionKey(shuffle: Boolean): String =
    if (shuffle) "player.tooltips.shuffle.disable" else "player.tooltips.shuffle.enable"

/** What tapping the repeat control does next: off → all → one → off. */
fun repeatActionKey(repeat: RepeatMode): String = when (repeat) {
    RepeatMode.Off -> "player.tooltips.repeat.enable"
    RepeatMode.All -> "player.tooltips.repeat.enableOne"
    RepeatMode.One -> "player.tooltips.repeat.disable"
}

@Composable
private fun PlayPauseButton(state: PlayerState, onClick: () -> Unit) {
    val palette = LocalPlayerPalette.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.9f else 1f,
        animationSpec = MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "playScale",
    )
    val effects = MaterialTheme.motionScheme.fastEffectsSpec<Float>()
    // The action stays the same while a song is buffering.
    val description = t(if (state.isPlaying) "player.tooltips.pause" else "player.tooltips.play")
    Box(
        modifier = Modifier
            .size(64.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(CircleShape)
            .background(palette.playContainer)
            .clickable(
                interactionSource = interaction,
                indication = ripple(color = palette.playContent),
                role = Role.Button,
                onClick = onClick,
            )
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        val icon = when {
            state.isLoading -> PlayIcon.Loading
            state.isPlaying -> PlayIcon.Pause
            else -> PlayIcon.Play
        }
        AnimatedContent(
            targetState = icon,
            transitionSpec = {
                (fadeIn(effects) + scaleIn(effects, initialScale = 0.8f)) togetherWith
                    (fadeOut(effects) + scaleOut(effects, targetScale = 0.8f))
            },
            label = "playIcon",
        ) { current ->
            when (current) {
                PlayIcon.Loading -> LoadingIndicator(
                    modifier = Modifier.size(36.dp),
                    color = palette.playContent,
                )
                PlayIcon.Pause -> Icon(
                    Icons.Rounded.Pause,
                    contentDescription = null,
                    tint = palette.playContent,
                    modifier = Modifier.size(34.dp),
                )
                PlayIcon.Play -> Icon(
                    Icons.Rounded.PlayArrow,
                    contentDescription = null,
                    tint = palette.playContent,
                    modifier = Modifier.size(34.dp),
                )
            }
        }
    }
}

private enum class PlayIcon { Loading, Pause, Play }

/** Icon button drawn in the player palette. */
@Composable
fun PlayerIconButton(
    icon: ImageVector,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    iconSize: Dp = 24.dp,
    tint: Color? = null,
) {
    val palette = LocalPlayerPalette.current
    IconButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = IconButtonDefaults.iconButtonColors(
            contentColor = tint ?: palette.content,
            disabledContentColor = palette.content.copy(alpha = DISABLED_ALPHA),
        ),
    ) {
        Icon(icon, contentDescription = description, modifier = Modifier.size(iconSize))
    }
}

/**
 * A small labeled button in the player palette: outlined, or filled while
 * what it stands for is [active].
 */
@Composable
fun PlayerPill(
    icon: ImageVector,
    label: String,
    active: Boolean,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    val palette = LocalPlayerPalette.current
    val content = when {
        !enabled -> palette.content.copy(alpha = 0.3f)
        active -> palette.content
        else -> palette.content.copy(alpha = 0.6f)
    }
    Row(
        modifier = Modifier
            .height(32.dp)
            .clip(CircleShape)
            .then(
                if (active) {
                    Modifier.background(palette.container)
                } else {
                    Modifier.border(BorderStroke(1.dp, palette.outline), CircleShape)
                },
            )
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(14.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = content,
            maxLines = 1,
        )
    }
}

/** Shuffle/repeat style control: tinted and marked with a dot while active. */
@Composable
fun ModeToggle(
    icon: ImageVector,
    active: Boolean,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val palette = LocalPlayerPalette.current
    IconToggleButton(
        checked = active,
        onCheckedChange = { onClick() },
        modifier = modifier,
        enabled = enabled,
        colors = IconButtonDefaults.iconToggleButtonColors(
            contentColor = palette.content,
            disabledContentColor = palette.content.copy(alpha = DISABLED_ALPHA),
            checkedContainerColor = Color.Transparent,
            checkedContentColor = palette.active,
        ),
    ) {
        Box(modifier = Modifier.size(40.dp), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = description, modifier = Modifier.size(24.dp))
            if (active) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .size(4.dp)
                        .background(LocalContentColor.current, CircleShape),
                )
            }
        }
    }
}

/** Mute button, system volume slider, and a loud-end marker. */
@Composable
fun VolumeBar(modifier: Modifier = Modifier) {
    val player = LocalAppGraph.current.player
    val palette = LocalPlayerPalette.current
    val volume by player.volume.collectAsStateWithLifecycle()
    // The volume keys change what the bar shows only for this device.
    val remote by player.remote.collectAsStateWithLifecycle()
    val local by remember { derivedStateOf { remote == null } }
    val link = LocalPlayerSheetLink.current
    DisposableEffect(link, local) {
        if (local) link.volumeBarShown()
        onDispose { if (local) link.volumeBarHidden() }
    }
    var beforeMute by remember { mutableFloatStateOf(0.5f) }
    val level = volume.toFloat().coerceIn(0f, 1f)
    val muted = level <= 0f

    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        PlayerIconButton(
            icon = when {
                muted -> Icons.AutoMirrored.Rounded.VolumeOff
                level < 0.5f -> Icons.AutoMirrored.Rounded.VolumeDown
                else -> Icons.AutoMirrored.Rounded.VolumeUp
            },
            description = t(
                if (muted) "player.tooltips.volume.unmute" else "player.tooltips.volume.mute",
            ),
            onClick = {
                if (muted) {
                    player.setVolume(beforeMute.toDouble())
                } else {
                    beforeMute = level
                    player.setVolume(0.0)
                }
            },
            iconSize = 20.dp,
            tint = palette.muted,
        )
        PlayerSlider(
            value = level,
            onValueChange = { player.setVolume(it.toDouble()) },
            onValueChangeFinished = { player.setVolume(it.toDouble()) },
            label = t("player.tooltips.volume.label"),
            modifier = Modifier.weight(1f),
            valueText = { "${(it * 100).roundToInt()}%" },
        )
        Icon(
            Icons.AutoMirrored.Rounded.VolumeUp,
            contentDescription = null,
            tint = palette.muted,
            modifier = Modifier
                .padding(horizontal = 14.dp)
                .size(20.dp),
        )
    }
}
