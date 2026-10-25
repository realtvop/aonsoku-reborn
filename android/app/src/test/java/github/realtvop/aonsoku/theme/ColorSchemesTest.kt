package github.realtvop.aonsoku.theme

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ColorSchemesTest {
    @Test
    fun shipsEveryWebThemeInItsGroup() {
        assertEquals(20, themePalettes.size)
        assertEquals(themePalettes.size, themePalettes.map { it.id }.toSet().size)
        assertEquals(
            listOf("light", "night-owl-light", "noctis-lilac", "achiever", "tinacious-design"),
            lightThemeIds,
        )
        assertTrue(DEFAULT_DARK_THEME in darkThemeIds)
        assertEquals(15, darkThemeIds.size)
    }

    @Test
    fun fallsBackToTheDefaultThemeOfTheRequestedBrightness() {
        assertEquals("dark", themePaletteFor("light", dark = true).id)
        assertEquals("light", themePaletteFor("dracula", dark = false).id)
        assertEquals("dracula", themePaletteFor("dracula", dark = true).id)
        assertEquals("light", themePaletteFor("unknown", dark = false).id)
    }

    @Test
    fun keepsTheWebSurfaceAndAccentColors() {
        for (palette in themePalettes) {
            val scheme = palette.toColorScheme()

            assertEquals(palette.id, palette.background, scheme.background)
            assertEquals(palette.id, palette.background, scheme.surface)
            assertEquals(palette.id, palette.foreground, scheme.onSurface)
            assertEquals(palette.id, palette.primary, scheme.primary)
            assertEquals(palette.id, palette.primaryForeground, scheme.onPrimary)
            assertEquals(palette.id, palette.mutedForeground, scheme.onSurfaceVariant)
        }
    }

    @Test
    fun derivesAContainerLadderThatMovesTowardTheForeground() {
        val scheme = themePaletteFor("dark", dark = true).toColorScheme()
        val ladder = listOf(
            scheme.surface,
            scheme.surfaceContainerLow,
            scheme.surfaceContainer,
            scheme.surfaceContainerHigh,
            scheme.surfaceContainerHighest,
        ).map { it.red + it.green + it.blue }

        assertEquals(ladder.sorted(), ladder)
        assertTrue(ladder.last() > ladder.first())
    }

    @Test
    fun picksReadableContentColors() {
        assertTrue(Color.Black.isDark())
        assertFalse(Color.White.isDark())
        assertEquals(Color.White, Color(0xFF102030).contentColor())
        assertFalse(Color(0xFFF5F5F5).contentColor() == Color.White)
    }
}
