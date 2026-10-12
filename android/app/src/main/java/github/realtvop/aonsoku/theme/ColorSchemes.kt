package github.realtvop.aonsoku.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance

const val DEFAULT_LIGHT_THEME = "light"
const val DEFAULT_DARK_THEME = "dark"

val lightThemeIds: List<String> = themePalettes.filterNot { it.isDark }.map { it.id }
val darkThemeIds: List<String> = themePalettes.filter { it.isDark }.map { it.id }

fun themePaletteFor(id: String, dark: Boolean): ThemePalette {
    val fallback = if (dark) DEFAULT_DARK_THEME else DEFAULT_LIGHT_THEME
    return themePalettes.firstOrNull { it.id == id && it.isDark == dark }
        ?: themePalettes.first { it.id == fallback }
}

/** Blend [amount] of [other] into the receiver. */
fun Color.blend(other: Color, amount: Float): Color = lerp(this, other, amount)

/** The red of a liked heart; the same on every theme, like the web app. */
val LikedColor = Color(0xFFEF4444)

fun Color.isDark(): Boolean = luminance() < 0.4f

/** A readable content color for arbitrary (for example artwork-derived) backgrounds. */
fun Color.contentColor(): Color = if (isDark()) Color.White else Color(0xFF111318)

/**
 * Maps the web theme tokens onto Material 3 roles. Surfaces keep the theme's
 * own background, while the container ladder is derived by tinting it toward
 * the foreground so Material components keep their tonal elevation.
 */
fun ThemePalette.toColorScheme(): ColorScheme {
    val tone = { amount: Float -> background.blend(foreground, amount) }
    val base = if (isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = primary,
        onPrimary = primaryForeground,
        primaryContainer = background.blend(primary, if (isDark) 0.28f else 0.18f),
        onPrimaryContainer = foreground.blend(primary, if (isDark) 0.25f else 0.45f),
        inversePrimary = background.blend(primary, 0.6f),
        secondary = primary.blend(foreground, 0.4f),
        onSecondary = background,
        secondaryContainer = accent.blend(primary, if (isDark) 0.16f else 0.10f),
        onSecondaryContainer = accentForeground,
        tertiary = primary.blend(foreground, 0.6f),
        onTertiary = background,
        tertiaryContainer = background.blend(primary, if (isDark) 0.16f else 0.10f),
        onTertiaryContainer = foreground,
        background = background,
        onBackground = foreground,
        surface = background,
        onSurface = foreground,
        surfaceVariant = muted,
        onSurfaceVariant = mutedForeground,
        surfaceTint = primary,
        inverseSurface = foreground,
        inverseOnSurface = background,
        // The web "destructive" token is a fill color; dark themes need a
        // lighter tone for error text drawn directly on the surface.
        error = if (isDark) Color(0xFFFFB4AB) else destructive,
        onError = if (isDark) Color(0xFF690005) else destructiveForeground,
        errorContainer = if (isDark) destructive else background.blend(destructive, 0.16f),
        onErrorContainer = if (isDark) {
            destructiveForeground
        } else {
            destructive.blend(Color.Black, 0.45f)
        },
        outline = border.blend(foreground, 0.35f),
        outlineVariant = border,
        scrim = Color.Black,
        surfaceBright = tone(if (isDark) 0.16f else 0f),
        surfaceDim = if (isDark) background else background.blend(Color.Black, 0.06f),
        surfaceContainerLowest = if (isDark) {
            background.blend(Color.Black, 0.25f)
        } else {
            background
        },
        surfaceContainerLow = tone(0.035f),
        surfaceContainer = tone(0.06f),
        surfaceContainerHigh = tone(0.09f),
        surfaceContainerHighest = tone(0.125f),
    )
}
