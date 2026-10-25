package github.realtvop.aonsoku.data.lyrics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LyricsParserTest {
    @Test
    fun recognizesLrcByItsTimestamps() {
        assertTrue(LyricsParser.isSynced("[ti:Low Tide]\n[00:12.50]First line"))
        assertTrue(LyricsParser.isSynced("  [01:02:03]Colon as the fraction separator"))
        assertFalse(LyricsParser.isSynced("[Chorus]\nJust words\nand more words"))
        assertFalse(LyricsParser.isSynced(""))
    }

    @Test
    fun parsesTimestampsOfEveryPrecision() {
        val lines = LyricsParser.parseLrc(
            """
            [00:01.5]tenths
            [00:02.25]hundredths
            [00:03.125]milliseconds
            [01:04:50]colon
            [00:05]whole seconds
            """.trimIndent(),
        )
        assertEquals(listOf(1_500L, 2_250L, 3_125L, 5_000L, 64_500L), lines.map { it.startMs })
        assertEquals("colon", lines.last().text)
    }

    @Test
    fun aLineEndsWhereTheNextOneStarts() {
        val lines = LyricsParser.parseLrc("[00:10.00]one\n[00:20.00]two", durationMs = 45_000)
        assertEquals(listOf(20_000L, 45_000L), lines.map { it.endMs })

        // Without the length of the song the last line gets a few seconds.
        assertEquals(25_000L, LyricsParser.parseLrc("[00:10.00]one\n[00:20.00]two").last().endMs)
    }

    @Test
    fun sortsLinesAndSkipsWhatIsNotTimed() {
        val lines = LyricsParser.parseLrc(
            """
            [ar:Blue Meridian]
            [00:20.00]second
            a line without a timestamp
            [00:10.00]first
            """.trimIndent(),
        )
        assertEquals(listOf("first", "second"), lines.map { it.text })
    }

    @Test
    fun repeatsALineThatCarriesSeveralTimestamps() {
        val lines = LyricsParser.parseLrc("[00:10.00][00:30.00]chorus\n[00:20.00]verse")
        assertEquals(listOf("chorus", "verse", "chorus"), lines.map { it.text })
        assertEquals(listOf(10_000L, 20_000L, 30_000L), lines.map { it.startMs })
    }

    @Test
    fun dropsWordTimestampsOfEnhancedLrc() {
        val lines = LyricsParser.parseLrc("[00:10.00]<00:10.00>Low <00:10.60>tide")
        assertEquals("Low tide", lines.single().text)
    }

    @Test
    fun keepsEmptyLinesAsPauses() {
        val lines = LyricsParser.parseLrc("[00:10.00]one\n[00:20.00]\n[00:40.00]two")
        assertEquals(listOf("one", "", "two"), lines.map { it.text })
        assertEquals(40_000L, lines[1].endMs)
    }

    @Test
    fun pairsLinesSharingATimestampAsLineAndTranslation() {
        val lines = LyricsParser.parseLrc(
            """
            [00:10.00]潮が引く
            [00:10.00]The tide goes out
            [00:20.00]一人で
            """.trimIndent(),
        )
        assertEquals(2, lines.size)
        assertEquals("潮が引く", lines[0].text)
        assertEquals("The tide goes out", lines[0].translation)
        assertEquals("", lines[1].translation)
    }

    @Test
    fun matchesTheRomanizationTrackByTimestamp() {
        val lines = LyricsParser.parseLrc(
            text = "[00:10.00]潮が引く\n[00:20.00]一人で",
            romaji = "[00:20.00]hitori de\n[00:10.00]shio ga hiku\n[00:30.00]nothing to match",
        )
        assertEquals(listOf("shio ga hiku", "hitori de"), lines.map { it.roman })
    }

    @Test
    fun convertsStructuredLyricsWithATranslationTrack() {
        val primary = StructuredLyrics(
            lang = "jpn",
            synced = true,
            line = listOf(StructuredLine(1_000, "潮が引く"), StructuredLine(5_000, "一人で")),
        )
        val translation = StructuredLyrics(
            lang = "eng",
            synced = true,
            line = listOf(StructuredLine(1_000, "The tide goes out")),
        )
        val lines = LyricsParser.fromStructured(primary, translation, durationMs = 9_000)
        assertEquals(listOf(1_000L, 5_000L), lines.map { it.startMs })
        assertEquals(listOf(5_000L, 9_000L), lines.map { it.endMs })
        assertEquals(listOf("The tide goes out", ""), lines.map { it.translation })
    }

    @Test
    fun pairsStructuredLinesSharingAStartWhenThereIsNoTranslationTrack() {
        val primary = StructuredLyrics(
            synced = true,
            line = listOf(
                StructuredLine(1_000, "extra"),
                StructuredLine(1_000, "潮が引く"),
                StructuredLine(1_000, "The tide goes out"),
                StructuredLine(5_000, "一人で"),
            ),
        )
        val lines = LyricsParser.fromStructured(primary)
        // Only the last two of a group are a pair; what precedes stands alone.
        assertEquals(listOf("extra", "潮が引く", "一人で"), lines.map { it.text })
        assertEquals(listOf("", "The tide goes out", ""), lines.map { it.translation })
    }

    @Test
    fun cleansPlainLyrics() {
        val lines = LyricsParser.plainLines("[ti:Low Tide]\n\n  First line  \n[00:12.00]Second line\n")
        assertEquals(listOf("First line", "Second line"), lines)
    }

    @Test
    fun structuredLyricsWinOverText() {
        val data = LyricsData(
            structured = listOf(StructuredLyrics(synced = true, line = listOf(StructuredLine(0, "structured")))),
            text = LyricsText("[00:01.00]text"),
        )
        val resolved = LyricsParser.resolve(data, showTranslation = true, durationMs = null) as Lyrics.Synced
        assertEquals("structured", resolved.lines.single().text)
    }

    @Test
    fun unsyncedStructuredLyricsArePlainWithTheirTranslation() {
        val data = LyricsData(
            structured = listOf(
                StructuredLyrics(line = listOf(StructuredLine(value = "潮が引く"))),
                StructuredLyrics(line = listOf(StructuredLine(value = "The tide goes out"))),
            ),
        )
        val shown = LyricsParser.resolve(data, showTranslation = true, durationMs = null) as Lyrics.Plain
        assertEquals(listOf("The tide goes out"), shown.translations)
        val hidden = LyricsParser.resolve(data, showTranslation = false, durationMs = null) as Lyrics.Plain
        assertTrue(hidden.translations.isEmpty())
    }

    @Test
    fun textIsSyncedWhenItIsLrcAndPlainOtherwise() {
        val lrc = LyricsData(text = LyricsText("[00:10.00]潮が引く\n[00:10.00]The tide", romaji = "[00:10.00]shio"))
        val synced = LyricsParser.resolve(lrc, showTranslation = false, durationMs = 30_000) as Lyrics.Synced
        assertTrue(synced.hasRoman)
        assertEquals("", synced.lines.single().translation)
        assertEquals(30_000L, synced.lines.single().endMs)

        val plain = LyricsParser.resolve(LyricsData(text = LyricsText("Just\nwords")), true, null)
        assertEquals(Lyrics.Plain(listOf("Just", "words")), plain)
    }

    @Test
    fun nothingToShowResolvesToNull() {
        assertNull(LyricsParser.resolve(LyricsData(), showTranslation = true, durationMs = null))
        assertNull(LyricsParser.resolve(LyricsData(text = LyricsText("  \n ")), true, null))
        // A structured track without words does not hide the text.
        val blank = LyricsData(
            structured = listOf(StructuredLyrics(synced = true, line = listOf(StructuredLine(0, " ")))),
            text = LyricsText("words"),
        )
        assertEquals(Lyrics.Plain(listOf("words")), LyricsParser.resolve(blank, true, null))
    }
}
