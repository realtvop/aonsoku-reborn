package github.realtvop.aonsoku.plugins.data
import github.realtvop.aonsoku.plugins.lyrics.LyricsParser
import org.junit.Assert.*
import org.junit.Test
class LyricsParserTest {
    @Test fun multipleTimestampsFractionsAndOffset() {
        val lines = LyricsParser.parse("[offset:-250]\n[01:02.5][02:03.125]Hello\n[00:01.01]First")
        assertEquals(listOf("First", "Hello", "Hello"), lines.map { it.text })
        assertEquals(0.76, lines[0].seconds!!, 0.0001)
        assertEquals(62.25, lines[1].seconds!!, 0.0001)
        assertEquals(122.875, lines[2].seconds!!, 0.0001)
    }
    @Test fun plainLyricsSkipMetadata() { assertEquals(listOf("Hello", "World"), LyricsParser.parse("[ar:Artist]\nHello\n\nWorld").map { it.text }) }
    @Test fun translationsKeepSharedTimestamp() { assertEquals(2, LyricsParser.parse("[00:01]Hello\n[00:01]你好").size) }
}
