package github.realtvop.aonsoku.ui

import android.content.Context
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import org.json.JSONObject

val LocalTranslations = staticCompositionLocalOf { JSONObject() }
@Composable fun L(text: String): String = LocalTranslations.current.optString(text, text)
fun nativeTranslations(context: Context, code: String): JSONObject {
    val locale = code.ifBlank { java.util.Locale.getDefault().toLanguageTag() }
    val all = JSONObject(context.assets.open("native/translations.json").bufferedReader().use { it.readText() })
    return all.optJSONObject(locale) ?: all.optJSONObject(locale.substringBefore('-')) ?: JSONObject()
}
fun nativeColors(context: Context, theme: String, dark: Boolean): ColorScheme {
    val palettes = JSONObject(context.assets.open("native/themes.json").bufferedReader().use { it.readText() })
    val palette = palettes.optJSONObject(theme) ?: palettes.getJSONObject(if (dark) "dark" else "light")
    fun color(key: String, fallback: Color): Color = palette.optString(key).takeIf(String::isNotBlank)?.let { Color(android.graphics.Color.parseColor(it)) } ?: fallback
    val base = if (dark) darkColorScheme() else lightColorScheme()
    val surface = color("background", base.surface)
    val onSurface = color("foreground", base.onSurface)
    return base.copy(primary = color("primary", base.primary), onPrimary = color("primary-foreground", base.onPrimary), background = surface, onBackground = onSurface, surface = surface, onSurface = onSurface, surfaceContainerLowest = surface, surfaceContainerLow = lerp(surface, onSurface, 0.03f), surfaceContainer = lerp(surface, onSurface, 0.05f), surfaceContainerHigh = lerp(surface, onSurface, 0.08f), surfaceContainerHighest = lerp(surface, onSurface, 0.11f), secondaryContainer = color("secondary", base.secondaryContainer), onSecondaryContainer = color("secondary-foreground", base.onSecondaryContainer), primaryContainer = lerp(surface, color("primary", base.primary), 0.22f), onPrimaryContainer = onSurface)
}
