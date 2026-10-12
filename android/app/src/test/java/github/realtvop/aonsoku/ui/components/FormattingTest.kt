package github.realtvop.aonsoku.ui.components

import github.realtvop.aonsoku.i18n.Translations
import github.realtvop.aonsoku.i18n.appLanguages
import org.junit.Assert.assertEquals
import org.junit.Test

class FormattingTest {
    private val strings = Translations(
        language = appLanguages.first { it.code == "en-US" },
        strings = mapOf(
            "time.days_one" to "{{days}} day",
            "time.days_other" to "{{days}} days",
            "time.hour" to "{{hour}} hr",
            "time.minutes" to "{{minutes}} min",
            "time.seconds" to "{{seconds}} s",
        ),
        fallback = emptyMap(),
        pluralCategory = { if (it == 1) "one" else "other" },
    )

    @Test
    fun clockShowsHoursOnlyFromOneHourOn() {
        assertEquals("00:00", formatClock(0))
        assertEquals("03:07", formatClock(187))
        assertEquals("59:59", formatClock(3599))
        assertEquals("01:00:00", formatClock(3600))
        assertEquals("02:03:04", formatClock(7384))
        assertEquals("00:00", formatClock(-5))
    }

    @Test
    fun spokenDurationShowsSecondsOnlyBelowOneHour() {
        assertEquals("03 min 07 s", strings.humanDuration(187))
        assertEquals("03 min", strings.humanDuration(180))
        assertEquals("01 hr 12 min", strings.humanDuration(4350))
    }

    @Test
    fun spokenDurationDropsMinutesForWholeHours() {
        assertEquals("02 hr", strings.humanDuration(7200))
        assertEquals("02 hr", strings.humanDuration(7230))
    }

    @Test
    fun spokenDurationCountsDays() {
        assertEquals("01 day 01 hr 01 min", strings.humanDuration(86_400 + 3600 + 60))
        assertEquals("02 days 00 min", strings.humanDuration(2 * 86_400))
    }

    @Test
    fun exactDurationAlwaysShowsMinutesAndSeconds() {
        assertEquals("01 hr 00 min 00 s", strings.humanDuration(3600, exact = true))
        assertEquals("00 min 09 s", strings.humanDuration(9, exact = true))
    }

    @Test
    fun bytesUseBinaryUnits() {
        assertEquals("0 Bytes", formatBytes(0))
        assertEquals("512.00 Bytes", formatBytes(512))
        assertEquals("1.00 KiB", formatBytes(1024))
        assertEquals("1.50 MiB", formatBytes(1024L * 1024 * 3 / 2))
        assertEquals("2.0 GiB", formatBytes(2L * 1024 * 1024 * 1024, decimals = 1))
    }
}
