package github.realtvop.aonsoku.plugins.data.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class SyncEngineSearchQueryTest {
    @Test
    fun navidromeUsesQuotedEmptyQuery() {
        assertEquals("\"\"", buildAllSongsQuery("navidrome"))
    }

    @Test
    fun subsonicUsesEmptyString() {
        assertEquals("", buildAllSongsQuery("subsonic"))
    }

    @Test
    fun unknownServerTypeDefaultsToEmptyString() {
        assertEquals("", buildAllSongsQuery(""))
        assertEquals("", buildAllSongsQuery("madsonic"))
        assertEquals("", buildAllSongsQuery("gonic"))
    }
}
