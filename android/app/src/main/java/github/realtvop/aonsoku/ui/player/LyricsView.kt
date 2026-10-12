package github.realtvop.aonsoku.ui.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.withInfiniteAnimationFrameNanos
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.LongState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.lyrics.LyricLine
import github.realtvop.aonsoku.data.lyrics.Lyrics
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerState
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

/** Where the line being sung rests, measured from the top of the lyrics. */
private val AnchorTop = 112.dp
private const val ANCHOR_SCREEN_FRACTION = 0.14f

/** Room below the last line, so that it can rise to where lines rest. */
private const val TAIL_SCREEN_FRACTION = 0.6f

/** Lines start where the cover of the song row above them does. */
private val LineInset = PlayerRowInset
private val LinePadding = PaddingValues(horizontal = PlayerRowContentInset, vertical = 10.dp)

/** Lines are sized by the width they have: about a dozen wide characters a line. */
private const val FONT_WIDTH_FRACTION = 0.075f
private const val FONT_MIN = 24f
private const val FONT_MAX = 34f
private const val LYRICS_MAX_WIDTH = 560
private const val LINE_HEIGHT = 1.22f
private const val SUB_LINE_SIZE = 0.55f

private const val INACTIVE_ALPHA = 0.28f
private const val SUB_LINE_ALPHA = 0.6f
private const val INACTIVE_SCALE = 0.97f

/** Lines blur more the further they are from the one being sung. */
private val BlurStep = 1.1.dp
private val BlurMax = 7.dp

private val EdgeFade = 40.dp

/** After a scroll by hand ends: when the controls return, and when the lyrics follow the song again. */
private const val ALIGN_RESTORE_MS = 500L
private const val FOLLOW_RESUME_MS = 5_000L

/** A pause between lines at least this long is shown as dots filling up. */
private const val INTERLUDE_MIN_MS = 4_000L
private val InterludeHeight = 40.dp
private val PauseHeight = 12.dp

/** How far the position runs ahead of the last report, in case no further one comes. */
private const val MAX_EXTRAPOLATION_MS = 500L

/** Reports arrive with a little jitter; stepping back this little would flicker between two lines. */
private const val JITTER_MS = 120L

/**
 * The lyrics tab: the song on top, its lyrics, and the playback controls,
 * which make room while the lyrics are scrolled by hand.
 */
@Composable
fun LyricsView(
    state: PlayerState,
    lyrics: PlayerLyrics,
    onShowPlaying: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val song = state.current
    val shown = lyrics.lyrics
    // False while the lyrics are scrolled by hand.
    var aligned by remember { mutableStateOf(true) }

    Column(modifier = modifier.fillMaxSize()) {
        if (song != null) CurrentSongRow(state = state, song = song, onClick = onShowPlaying)
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            when {
                song == null -> LyricsMessage(t("player.noSongPlaying"))
                shown is Lyrics.Synced -> SyncedLyrics(
                    lyrics = shown,
                    offsetMs = lyrics.offsetMs,
                    advancing = state.isPlaying && !state.isLoading,
                    aligned = aligned,
                    onAlignedChange = { aligned = it },
                )
                shown is Lyrics.Plain -> PlainLyrics(shown)
                lyrics.loading -> LyricsMessage(t("fullscreen.loadingLyrics"))
                else -> LyricsMessage(t("fullscreen.noLyrics"))
            }
        }
        AnimatedVisibility(
            visible = aligned,
            enter = expandVertically() + fadeIn(),
            exit = shrinkVertically() + fadeOut(),
        ) {
            Column(
                modifier = Modifier
                    .padding(horizontal = 24.dp)
                    .padding(top = 4.dp),
            ) {
                PlayerProgress()
                TransportControls(state, modifier = Modifier.padding(top = 4.dp))
                VolumeBar(modifier = Modifier.padding(top = 8.dp))
            }
        }
    }
}

/** The line being sung and the line the list rests on, which is the next one during a gap. */
internal data class LyricPosition(val active: Int, val anchor: Int)

internal fun lyricPositionAt(lines: List<LyricLine>, timeMs: Long): LyricPosition {
    var low = 0
    var high = lines.lastIndex
    var started = -1
    while (low <= high) {
        val middle = (low + high) ushr 1
        if (lines[middle].startMs <= timeMs) {
            started = middle
            low = middle + 1
        } else {
            high = middle - 1
        }
    }
    if (started < 0) return LyricPosition(active = -1, anchor = 0)
    if (timeMs < lines[started].endMs) return LyricPosition(active = started, anchor = started)
    return LyricPosition(active = -1, anchor = minOf(started + 1, lines.lastIndex))
}

/**
 * Timed lyrics that follow the song: the line being sung is lit and rests near
 * the top, the others are dimmed and out of focus. A tap on a line seeks to
 * it; scrolling by hand pauses the following for a moment.
 */
@Composable
private fun SyncedLyrics(
    lyrics: Lyrics.Synced,
    offsetMs: Long,
    advancing: Boolean,
    aligned: Boolean,
    onAlignedChange: (Boolean) -> Unit,
) {
    val player = LocalAppGraph.current.player
    val lines = lyrics.lines
    val clock = rememberPlaybackClock(advancing)
    val offset = rememberUpdatedState(offsetMs)
    val position by remember(lines) {
        derivedStateOf { lyricPositionAt(lines, clock.longValue - offset.value) }
    }

    val configuration = LocalConfiguration.current
    val anchorTop = minOf(AnchorTop, configuration.screenHeightDp.dp * ANCHOR_SCREEN_FRACTION)
    val tail = configuration.screenHeightDp.dp * TAIL_SCREEN_FRACTION
    val fontSize = (minOf(configuration.screenWidthDp, LYRICS_MAX_WIDTH) * FONT_WIDTH_FRACTION)
        .coerceIn(FONT_MIN, FONT_MAX).sp

    val listState = remember(lines) { LazyListState() }
    var following by remember(lines) { mutableStateOf(true) }
    var placed by remember(lines) { mutableStateOf(false) }
    val onAligned by rememberUpdatedState(onAlignedChange)

    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect { interaction ->
            if (interaction is DragInteraction.Start) {
                following = false
                onAligned(false)
            }
        }
    }
    LaunchedEffect(listState, following) {
        if (following) return@LaunchedEffect
        snapshotFlow { listState.isScrollInProgress }.collectLatest { scrolling ->
            if (scrolling) return@collectLatest
            delay(ALIGN_RESTORE_MS)
            onAligned(true)
            delay(FOLLOW_RESUME_MS - ALIGN_RESTORE_MS)
            following = true
        }
    }
    LaunchedEffect(listState, position.anchor, following) {
        if (!following) return@LaunchedEffect
        if (placed) {
            listState.animateScrollToItem(position.anchor)
        } else {
            listState.scrollToItem(position.anchor)
            placed = true
        }
    }
    // Other lyrics, or no timed lyrics any more: whatever was scrolled is gone.
    DisposableEffect(lines) {
        onAligned(true)
        onDispose { onAligned(true) }
    }

    LazyColumn(
        state = listState,
        modifier = Modifier
            .fillMaxSize()
            .fadingEdges(EdgeFade),
        contentPadding = PaddingValues(top = anchorTop, bottom = tail),
    ) {
        itemsIndexed(lines) { index, line ->
            val active = index == position.active
            if (line.text.isBlank() && line.translation.isBlank()) {
                PauseLine(line = line, active = active, clock = clock, offsetMs = { offset.value })
            } else {
                SyncedLine(
                    line = line,
                    active = active,
                    // Lines that were sung are a step further out of focus than those to come.
                    blurSteps = when {
                        !aligned || active -> 0
                        index < position.anchor -> position.anchor - index + 2
                        else -> index - position.anchor + 1
                    },
                    fontSize = fontSize,
                    onClick = {
                        player.seek((line.startMs + offset.value).coerceAtLeast(0L) / 1000.0)
                        following = true
                        onAligned(true)
                    },
                )
            }
        }
    }
}

@Composable
private fun SyncedLine(
    line: LyricLine,
    active: Boolean,
    blurSteps: Int,
    fontSize: TextUnit,
    onClick: () -> Unit,
) {
    val motion = MaterialTheme.motionScheme
    val alpha by animateFloatAsState(
        targetValue = if (active) 1f else INACTIVE_ALPHA,
        animationSpec = motion.defaultEffectsSpec(),
        label = "lyricAlpha",
    )
    val scale by animateFloatAsState(
        targetValue = if (active) 1f else INACTIVE_SCALE,
        animationSpec = motion.defaultSpatialSpec(),
        label = "lyricScale",
    )
    val blur by animateDpAsState(
        targetValue = minOf(BlurStep * blurSteps, BlurMax),
        animationSpec = motion.defaultEffectsSpec(),
        label = "lyricBlur",
    )
    val main = MaterialTheme.typography.headlineMedium.copy(
        fontSize = fontSize,
        lineHeight = fontSize * LINE_HEIGHT,
        fontWeight = FontWeight.Bold,
    )
    val sub = MaterialTheme.typography.titleMedium.copy(
        fontSize = fontSize * SUB_LINE_SIZE,
        lineHeight = fontSize * SUB_LINE_SIZE * LINE_HEIGHT,
        fontWeight = FontWeight.Medium,
        color = LocalContentColor.current.copy(alpha = SUB_LINE_ALPHA),
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = LineInset)
            .clip(MaterialTheme.shapes.medium)
            .clickable(onClick = onClick)
            .semantics { selected = active }
            .padding(LinePadding)
            .graphicsLayer {
                this.alpha = alpha
                scaleX = scale
                scaleY = scale
                transformOrigin = TransformOrigin(0f, 0.5f)
            }
            // Only Android 12 and later can blur; before that the lines are just dimmed.
            .then(if (blur > 0.dp) Modifier.blur(blur, BlurredEdgeTreatment.Unbounded) else Modifier),
    ) {
        // A romanization reads above the line, a translation below it.
        if (line.roman.isNotEmpty()) Text(text = line.roman, style = sub)
        Text(text = line.text, style = main)
        if (line.translation.isNotEmpty()) Text(text = line.translation, style = sub)
    }
}

/** A line without words: a gap, or three dots filling up while a long pause lasts. */
@Composable
private fun PauseLine(line: LyricLine, active: Boolean, clock: LongState, offsetMs: () -> Long) {
    val duration = line.endMs - line.startMs
    if (duration < INTERLUDE_MIN_MS) {
        Box(Modifier.height(PauseHeight))
        return
    }
    val alpha by animateFloatAsState(
        targetValue = if (active) 1f else 0f,
        animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "interludeAlpha",
    )
    val color = LocalContentColor.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(InterludeHeight)
            .padding(horizontal = LineInset + PlayerRowContentInset),
        contentAlignment = Alignment.CenterStart,
    ) {
        Canvas(
            modifier = Modifier
                .size(width = 52.dp, height = 12.dp)
                .graphicsLayer { this.alpha = alpha },
        ) {
            // Not read while hidden, so that only the pause being played redraws with the clock.
            if (alpha == 0f) return@Canvas
            val progress = ((clock.longValue - offsetMs() - line.startMs).toFloat() / duration).coerceIn(0f, 1f)
            val radius = size.height / 2
            repeat(INTERLUDE_DOTS) { dot ->
                val filled = (progress * INTERLUDE_DOTS - dot).coerceIn(0f, 1f)
                drawCircle(
                    color = color,
                    radius = radius * (0.7f + 0.3f * filled),
                    center = Offset(radius + dot * (size.width - 2 * radius) / (INTERLUDE_DOTS - 1), radius),
                    alpha = INACTIVE_ALPHA + (1f - INACTIVE_ALPHA) * filled,
                )
            }
        }
    }
}

private const val INTERLUDE_DOTS = 3

/** Lyrics without timestamps, to read and scroll. */
@Composable
private fun PlainLyrics(lyrics: Lyrics.Plain) {
    val palette = LocalPlayerPalette.current
    val listState = remember(lyrics) { LazyListState() }
    LazyColumn(
        state = listState,
        modifier = Modifier
            .fillMaxSize()
            .fadingEdges(EdgeFade),
        contentPadding = PaddingValues(horizontal = LineInset + PlayerRowContentInset, vertical = 24.dp),
    ) {
        itemsIndexed(lyrics.lines) { index, line ->
            Column(modifier = Modifier.padding(vertical = 4.dp)) {
                Text(
                    text = line,
                    style = MaterialTheme.typography.titleLarge.copy(lineHeight = 32.sp),
                    fontWeight = FontWeight.SemiBold,
                )
                val translation = lyrics.translations.getOrNull(index).orEmpty()
                if (translation.isNotEmpty()) {
                    Text(
                        text = translation,
                        style = MaterialTheme.typography.bodyLarge,
                        color = palette.muted,
                    )
                }
            }
        }
    }
}

@Composable
private fun LyricsMessage(text: String) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
    }
}

/** Lets the content fade out towards the top and the bottom instead of being cut off. */
private fun Modifier.fadingEdges(height: Dp): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        if (size.height <= 0f) return@drawWithContent
        val fraction = (height.toPx() / size.height).coerceAtMost(0.5f)
        drawRect(
            brush = Brush.verticalGradient(
                0f to Color.Transparent,
                fraction to Color.Black,
                1f - fraction to Color.Black,
                1f to Color.Transparent,
            ),
            blendMode = BlendMode.DstIn,
        )
    }

/** The last position the service reported and when. */
private class PositionReport(var positionMs: Long, var atNanos: Long)

/**
 * The playback position in milliseconds. The service reports it a few times a
 * second; while the song plays, the frames in between move it along so that
 * lines change on time.
 */
@Composable
private fun rememberPlaybackClock(advancing: Boolean): LongState {
    val player = LocalAppGraph.current.player
    val clock = remember { mutableLongStateOf((player.progress.value.position * 1000).toLong()) }
    val report = remember { PositionReport(clock.longValue, System.nanoTime()) }

    fun moveTo(positionMs: Long) {
        val back = clock.longValue - positionMs
        if (back <= 0 || back > JITTER_MS) clock.longValue = positionMs
    }

    LaunchedEffect(player) {
        player.progress.collect { progress ->
            report.positionMs = (progress.position * 1000).toLong()
            report.atNanos = System.nanoTime()
            moveTo(report.positionMs)
        }
    }
    LaunchedEffect(advancing) {
        if (!advancing) return@LaunchedEffect
        while (true) {
            withInfiniteAnimationFrameNanos { }
            val elapsedMs = (System.nanoTime() - report.atNanos) / 1_000_000
            moveTo(report.positionMs + elapsedMs.coerceIn(0L, MAX_EXTRAPOLATION_MS))
        }
    }
    return clock
}
