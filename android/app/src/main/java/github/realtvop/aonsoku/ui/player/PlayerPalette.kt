package github.realtvop.aonsoku.ui.player

import android.util.LruCache
import androidx.compose.animation.animateColorAsState
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.ui.components.averageColor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Colors of the full-screen player. Its backdrop is the page background tinted
 * with the artwork color, so the content colors follow the brightness of that
 * blend rather than the theme (the web "backdrop-dark" / "backdrop-light").
 */
@Immutable
data class PlayerPalette(
    val isDark: Boolean,
    val content: Color,
    /** Secondary text such as the artist line. */
    val muted: Color,
    /** Tertiary text such as time labels and section actions. */
    val faint: Color,
    /** Enabled shuffle and repeat. */
    val active: Color,
    /** Fill of the selected tab and of enabled mode pills. */
    val container: Color,
    val outline: Color,
    val playContainer: Color,
    val playContent: Color,
    val sliderTrack: Color,
    val sliderRange: Color,
)

val LocalPlayerPalette = staticCompositionLocalOf<PlayerPalette> {
    error("PlayerPalette is not provided")
}

/**
 * The backdrop color as it animates from one song's tint to the next. Read it
 * while drawing: every song changes it, and reading it during composition
 * would recompose the whole player for each frame of that animation.
 */
val LocalPlayerBackdrop = staticCompositionLocalOf<State<Color>> {
    error("The player backdrop is not provided")
}

/**
 * The theme background mixed with [songColor] at [intensity]; without a color
 * the backdrop is the plain background.
 */
@Composable
fun rememberBackdropColor(songColor: Color?, intensity: Float): Color {
    val base = MaterialTheme.colorScheme.background
    return remember(base, songColor, intensity) {
        if (songColor != null) mixSrgb(base, songColor, intensity) else base
    }
}

/** Palette for content drawn on [backdrop]; it only changes with the backdrop's brightness. */
@Composable
fun rememberPlayerPalette(backdrop: Color): PlayerPalette {
    val dark = backdrop.luminance() < DARK_BACKDROP_LUMINANCE
    val spec = MaterialTheme.motionScheme.slowEffectsSpec<Color>()
    val content by animateColorAsState(
        targetValue = if (dark) Color.White else LightContent,
        animationSpec = spec,
        label = "playerContent",
    )
    val active by animateColorAsState(
        targetValue = if (dark) Color.White else LightActive,
        animationSpec = spec,
        label = "playerActive",
    )
    val range by animateColorAsState(
        targetValue = if (dark) Color.White else LightRange,
        animationSpec = spec,
        label = "playerRange",
    )
    val track by animateColorAsState(
        targetValue = if (dark) Color.White.copy(alpha = 0.3f) else LightTrack,
        animationSpec = spec,
        label = "playerTrack",
    )
    val playContent by animateColorAsState(
        targetValue = if (dark) Color.Black else Color.White,
        animationSpec = spec,
        label = "playerPlayContent",
    )
    return remember(dark, content, active, range, track, playContent) {
        PlayerPalette(
            isDark = dark,
            content = content,
            muted = content.copy(alpha = 0.7f),
            faint = content.copy(alpha = 0.5f),
            active = active,
            container = content.copy(alpha = 0.14f),
            outline = content.copy(alpha = 0.3f),
            playContainer = content,
            playContent = playContent,
            sliderTrack = track,
            sliderRange = range,
        )
    }
}

/**
 * Average color of [art], kept while the next artwork is still loading so the
 * backdrop moves from one song's tint to the next without flashing.
 */
@Composable
fun rememberArtworkColor(art: CoverArt): Color? {
    val context = LocalContext.current
    var color by remember { mutableStateOf(ArtworkColors[art]) }
    LaunchedEffect(art) {
        val key = art.ids.firstOrNull()
        if (key == null) {
            color = null
            return@LaunchedEffect
        }
        ArtworkColors[art]?.let {
            color = it
            return@LaunchedEffect
        }
        val computed = runSuspendCatching {
            val request = ImageRequest.Builder(context)
                .data(art)
                .size(ARTWORK_SAMPLE_PX)
                .allowHardware(false)
                .build()
            val result = SingletonImageLoader.get(context).execute(request)
            val bitmap = (result as? SuccessResult)?.image?.toBitmap()
            bitmap?.let { withContext(Dispatchers.Default) { averageColor(it) } }
        }.getOrNull()
        if (computed != null) ArtworkColors[art] = computed
        color = computed
    }
    return color
}

/** Artwork tints by cover id; only the songs played recently matter. */
private object ArtworkColors {
    private val cache = LruCache<String, Color>(64)

    operator fun get(art: CoverArt): Color? = art.ids.firstOrNull()?.let(cache::get)

    operator fun set(art: CoverArt, color: Color) {
        art.ids.firstOrNull()?.let { cache.put(it, color) }
    }
}

/** Per-channel sRGB mix, the blend the web player uses for its backdrop. */
private fun mixSrgb(base: Color, overlay: Color, amount: Float): Color {
    val alpha = amount.coerceIn(0f, 1f)
    return Color(
        red = base.red + (overlay.red - base.red) * alpha,
        green = base.green + (overlay.green - base.green) * alpha,
        blue = base.blue + (overlay.blue - base.blue) * alpha,
    )
}

private const val DARK_BACKDROP_LUMINANCE = 0.43f
private const val ARTWORK_SAMPLE_PX = 96

private val LightContent = Color(0xFF22252A)
private val LightActive = Color(0xFF059467)
private val LightRange = Color(0xFF111827)
private val LightTrack = Color(0xFF6B7280).copy(alpha = 0.7f)
