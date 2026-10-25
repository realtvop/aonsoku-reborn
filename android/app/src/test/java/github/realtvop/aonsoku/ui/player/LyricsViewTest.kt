package github.realtvop.aonsoku.ui.player

import github.realtvop.aonsoku.data.lyrics.LyricLine
import org.junit.Assert.assertEquals
import org.junit.Test

class LyricsViewTest {
    private val lines = listOf(
        LyricLine(startMs = 1_000, endMs = 3_000, text = "one"),
        LyricLine(startMs = 3_000, endMs = 6_000, text = "two"),
        LyricLine(startMs = 6_000, endMs = 9_000, text = "three"),
    )

    @Test
    fun beforeTheFirstLineNothingIsSungAndTheListRestsOnIt() {
        assertEquals(LyricPosition(active = -1, anchor = 0), lyricPositionAt(lines, 0))
        assertEquals(LyricPosition(active = -1, anchor = 0), lyricPositionAt(lines, 999))
    }

    @Test
    fun aLineIsSungFromItsStartUntilTheNextOneStarts() {
        assertEquals(LyricPosition(0, 0), lyricPositionAt(lines, 1_000))
        assertEquals(LyricPosition(0, 0), lyricPositionAt(lines, 2_999))
        assertEquals(LyricPosition(1, 1), lyricPositionAt(lines, 3_000))
        assertEquals(LyricPosition(2, 2), lyricPositionAt(lines, 8_999))
    }

    @Test
    fun afterTheLastLineTheListStaysOnIt() {
        assertEquals(LyricPosition(active = -1, anchor = 2), lyricPositionAt(lines, 9_000))
        assertEquals(LyricPosition(active = -1, anchor = 2), lyricPositionAt(lines, 60_000))
    }

    @Test
    fun aGapBetweenLinesRestsOnTheLineToCome() {
        val gapped = listOf(
            LyricLine(startMs = 0, endMs = 2_000, text = "one"),
            LyricLine(startMs = 5_000, endMs = 7_000, text = "two"),
        )
        assertEquals(LyricPosition(active = -1, anchor = 1), lyricPositionAt(gapped, 3_000))
    }

    @Test
    fun linesSharingAStartLightTheLastOfThem() {
        val grouped = listOf(
            LyricLine(startMs = 1_000, endMs = 1_000, text = "extra"),
            LyricLine(startMs = 1_000, endMs = 4_000, text = "line"),
        )
        assertEquals(LyricPosition(1, 1), lyricPositionAt(grouped, 1_500))
    }

    @Test
    fun aLateFirstLineIsPrecededByAPauseFromTheStart() {
        val late = listOf(LyricLine(6_000, 9_000, "First"), LyricLine(9_000, 12_000, "Second"))
        val shown = withIntroPause(late)
        assertEquals(listOf("", "First", "Second"), shown.map { it.text })
        assertEquals(0L to 6_000L, shown.first().startMs to shown.first().endMs)
        assertEquals(LyricPosition(active = 0, anchor = 0), lyricPositionAt(shown, 1_000))

        // An early first line needs no pause, and a pause that is there already starts at zero.
        val early = listOf(LyricLine(2_000, 4_000, "First"))
        assertEquals(early, withIntroPause(early))
        val paused = listOf(LyricLine(5_000, 9_000, ""), LyricLine(9_000, 12_000, "First"))
        assertEquals(listOf(0L, 9_000L), withIntroPause(paused).map { it.startMs })
    }

    @Test
    fun noLinesIsNoPosition() {
        assertEquals(LyricPosition(active = -1, anchor = 0), lyricPositionAt(emptyList(), 5_000))
    }

    @Test
    fun offsetsAreShownInTenthsWithASignWhenShifted() {
        assertEquals("0.0s", formatLyricsOffset(0.0))
        assertEquals("+0.3s", formatLyricsOffset(0.3))
        assertEquals("+2.0s", formatLyricsOffset(2.0))
        assertEquals("-1.2s", formatLyricsOffset(-1.2))
        assertEquals("0.0s", formatLyricsOffset(-0.04))
    }
}
