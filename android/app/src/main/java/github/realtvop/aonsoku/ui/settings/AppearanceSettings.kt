package github.realtvop.aonsoku.ui.settings

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.LightMode
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.settings.ThemeMode
import github.realtvop.aonsoku.theme.ThemePalette
import github.realtvop.aonsoku.theme.darkThemeIds
import github.realtvop.aonsoku.theme.isMaterialYouAvailable
import github.realtvop.aonsoku.theme.lightThemeIds
import github.realtvop.aonsoku.theme.themePaletteFor

private const val WIDE_SCREEN_DP = 600
private const val THEME_COLUMNS = 2
private const val THEME_COLUMNS_WIDE = 4
private val PreviewShape = RoundedCornerShape(10.dp)
private val SwatchShape = RoundedCornerShape(3.dp)

/** Covers, the light or dark mode, and the theme of each of them. */
@Composable
internal fun AppearanceSettings() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val columns = if (LocalConfiguration.current.screenWidthDp >= WIDE_SCREEN_DP) {
        THEME_COLUMNS_WIDE
    } else {
        THEME_COLUMNS
    }
    val materialYou = settings.materialYou && isMaterialYouAvailable()
    val modeLight = t("theme.modeLight")
    val modeDark = t("theme.modeDark")
    val modeSystem = t("theme.modeSystem")

    SettingsPage(title = t("settings.options.appearance")) {
        settingsSection(
            key = "general",
            title = strings.t("settings.appearance.general.group"),
            description = strings.t("settings.appearance.general.description"),
        ) {
            item {
                SwitchSetting(
                    title = t("settings.appearance.general.albumCoverForSongs.label"),
                    info = t("settings.appearance.general.albumCoverForSongs.info"),
                    checked = settings.useAlbumCoverForSongs,
                    onCheckedChange = { enabled ->
                        graph.settings.update { it.copy(useAlbumCoverForSongs = enabled) }
                    },
                )
            }
        }
        settingsSection(key = "theme", title = strings.t("theme.label")) {
            item {
                ChoiceSetting(
                    title = null,
                    options = listOf(
                        ThemeMode.Light to modeLight,
                        ThemeMode.Dark to modeDark,
                        ThemeMode.System to modeSystem,
                    ),
                    selected = settings.themeMode,
                    onSelect = { mode -> graph.settings.update { it.copy(themeMode = mode) } },
                    icons = mapOf(
                        ThemeMode.Light to Icons.Rounded.LightMode,
                        ThemeMode.Dark to Icons.Rounded.DarkMode,
                        ThemeMode.System to Icons.Rounded.Computer,
                    ),
                )
            }
            if (isMaterialYouAvailable()) {
                item {
                    SwitchSetting(
                        title = t("theme.materialYou"),
                        info = t("theme.materialYouInfo"),
                        checked = settings.materialYou,
                        onCheckedChange = { enabled ->
                            graph.settings.update { it.copy(materialYou = enabled) }
                        },
                    )
                }
            }
        }
        // The wallpaper colors replace the themes while they are in use.
        if (!materialYou) {
            val pickLight = { id: String -> graph.settings.update { it.copy(lightTheme = id) } }
            val pickDark = { id: String -> graph.settings.update { it.copy(darkTheme = id) } }
            when (settings.themeMode) {
                ThemeMode.Light -> themeGrid("light", null, lightThemeIds, false, settings.lightTheme, columns, pickLight)
                ThemeMode.Dark -> themeGrid("dark", null, darkThemeIds, true, settings.darkTheme, columns, pickDark)
                ThemeMode.System -> {
                    themeGrid("light", modeLight, lightThemeIds, false, settings.lightTheme, columns, pickLight)
                    themeGrid("dark", modeDark, darkThemeIds, true, settings.darkTheme, columns, pickDark)
                }
            }
        }
    }
}

/** The themes of one mode as rows of previews. */
private fun LazyListScope.themeGrid(
    key: String,
    label: String?,
    themes: List<String>,
    dark: Boolean,
    selected: String,
    columns: Int,
    onSelect: (String) -> Unit,
) {
    if (label != null) {
        item(key = "$key-label") {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
            )
        }
    }
    items(themes.chunked(columns), key = { row -> "$key-${row.first()}" }) { row ->
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            for (id in row) {
                ThemeOption(
                    palette = themePaletteFor(id, dark),
                    selected = id == selected,
                    onSelect = { onSelect(id) },
                    modifier = Modifier.weight(1f),
                )
            }
            // A last row that is not full keeps the width of its cells.
            repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

@Composable
private fun ThemeOption(
    palette: ThemePalette,
    selected: Boolean,
    onSelect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val color = if (selected) {
        MaterialTheme.colorScheme.onSurface
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant
    }
    Column(
        modifier = modifier
            .clip(MaterialTheme.shapes.medium)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .padding(4.dp),
    ) {
        ThemePreview(
            palette = palette,
            outline = if (selected) MaterialTheme.colorScheme.primary else palette.border,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(
            modifier = Modifier.padding(top = 8.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = if (selected) Icons.Rounded.Check else Icons.Rounded.Remove,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = t("theme.${palette.id}"),
                style = MaterialTheme.typography.labelMedium,
                color = color,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** A theme as a tiny app: a side bar with entries next to blocks in its main colors. */
@Composable
private fun ThemePreview(palette: ThemePalette, outline: Color, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .aspectRatio(1.6f)
            .clip(PreviewShape)
            .background(palette.background)
            .border(BorderStroke(if (outline == palette.border) 1.dp else 2.dp, outline), PreviewShape),
    ) {
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .weight(1f)
                .padding(6.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            repeat(5) { Swatch(palette.accent, Modifier.weight(1f)) }
        }
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .width(1.dp)
                .background(palette.border),
        )
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .weight(2f)
                .background(palette.backgroundForeground)
                .padding(6.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            for (color in listOf(palette.accent, palette.primary, palette.muted, palette.secondary)) {
                Swatch(color, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun Swatch(color: Color, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .clip(SwatchShape)
            .background(color),
    )
}
