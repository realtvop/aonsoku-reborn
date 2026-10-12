package github.realtvop.aonsoku.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.settings.AppSettings
import github.realtvop.aonsoku.settings.ThemeMode

/** Whether the resolved app theme (not necessarily the system) is dark. */
val LocalIsDarkTheme = staticCompositionLocalOf { false }

fun isMaterialYouAvailable(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

@Composable
fun resolveDarkTheme(mode: ThemeMode): Boolean = when (mode) {
    ThemeMode.Light -> false
    ThemeMode.Dark -> true
    ThemeMode.System -> isSystemInDarkTheme()
}

@Composable
fun rememberAppColorScheme(settings: AppSettings, dark: Boolean): ColorScheme {
    val context = LocalContext.current
    val useDynamic = settings.materialYou && isMaterialYouAvailable()
    val themeId = if (dark) settings.darkTheme else settings.lightTheme
    return remember(useDynamic, themeId, dark, context.resources.configuration) {
        if (useDynamic && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else {
            themePaletteFor(themeId, dark).toColorScheme()
        }
    }
}

@Composable
fun AonsokuTheme(
    settings: AppSettings,
    dark: Boolean = resolveDarkTheme(settings.themeMode),
    content: @Composable () -> Unit,
) {
    val colorScheme = rememberAppColorScheme(settings, dark)
    val context = LocalContext.current
    val typography = remember(context) { aonsokuTypography(brandFontFamily(context.assets)) }

    MaterialExpressiveTheme(
        colorScheme = colorScheme,
        motionScheme = MotionScheme.expressive(),
        shapes = AonsokuShapes,
        typography = typography,
    ) {
        CompositionLocalProvider(LocalIsDarkTheme provides dark, content = content)
    }
}

/** Re-theme a subtree with an explicit color scheme, keeping type and motion. */
@Composable
fun AonsokuSubTheme(
    colorScheme: ColorScheme,
    dark: Boolean,
    content: @Composable () -> Unit,
) {
    MaterialExpressiveTheme(
        colorScheme = colorScheme,
        motionScheme = MotionScheme.expressive(),
        shapes = MaterialTheme.shapes,
        typography = MaterialTheme.typography,
    ) {
        CompositionLocalProvider(LocalIsDarkTheme provides dark, content = content)
    }
}

private val AonsokuShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

/** Poppins, the typeface of the web app, packaged from `public/fonts`. */
private fun brandFontFamily(assets: android.content.res.AssetManager): FontFamily =
    runCatching {
        FontFamily(
            Font("fonts/Poppins-Regular.ttf", assets, FontWeight.Normal),
            Font("fonts/Poppins-Medium.ttf", assets, FontWeight.Medium),
            Font("fonts/Poppins-SemiBold.ttf", assets, FontWeight.SemiBold),
            Font("fonts/Poppins-Bold.ttf", assets, FontWeight.Bold),
        )
    }.getOrDefault(FontFamily.Default)

private fun aonsokuTypography(family: FontFamily): Typography {
    val base = Typography()
    fun TextStyle.brand(weight: FontWeight? = null): TextStyle =
        copy(fontFamily = family, fontWeight = weight ?: fontWeight)
    return Typography(
        displayLarge = base.displayLarge.brand(FontWeight.Bold),
        displayMedium = base.displayMedium.brand(FontWeight.Bold),
        displaySmall = base.displaySmall.brand(FontWeight.Bold),
        headlineLarge = base.headlineLarge.brand(FontWeight.Bold),
        headlineMedium = base.headlineMedium.brand(FontWeight.Bold),
        headlineSmall = base.headlineSmall.brand(FontWeight.Bold),
        titleLarge = base.titleLarge.brand(FontWeight.SemiBold),
        titleMedium = base.titleMedium.brand(FontWeight.SemiBold),
        titleSmall = base.titleSmall.brand(FontWeight.Medium),
        bodyLarge = base.bodyLarge.brand(),
        bodyMedium = base.bodyMedium.brand(),
        bodySmall = base.bodySmall.brand(),
        labelLarge = base.labelLarge.brand(FontWeight.Medium),
        labelMedium = base.labelMedium.brand(FontWeight.Medium),
        labelSmall = base.labelSmall.brand(FontWeight.Medium),
    )
}
