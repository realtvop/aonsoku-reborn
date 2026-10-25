package github.realtvop.aonsoku.data.lyrics

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class LyricsStoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val song = LyricsSong("so-1", "Blue Meridian", "Low Tide", "Tidal Hours", 187.0, "a/b/c.flac")

    private fun store() = LyricsStore(File(folder.root, "choices"), File(folder.root, "cache"))

    @Test
    fun keepsTheChosenLyricsWithTheirRomanization() = runBlocking {
        val store = store()
        assertNull(store.choice(song.key))

        store.saveChoice(song.key, "[00:01.00]潮", "[00:01.00]shio")
        assertEquals(LyricsText("[00:01.00]潮", "[00:01.00]shio"), store().choice(song.key))

        // Another choice without a romanization does not keep the old one.
        store.saveChoice(song.key, "[00:01.00]tide", null)
        assertEquals(LyricsText("[00:01.00]tide"), store.choice(song.key))

        store.deleteChoices(listOf(song.key))
        assertNull(store.choice(song.key))
    }

    @Test
    fun cachesAnswersPerSongAndSettings() = runBlocking {
        val store = store()
        val other = song.copy(title = "Undertow")
        store.cache(song, "auto", LyricsText("first"))
        store.cache(song, "custom", LyricsText("second", "romaji"))
        store.cache(other, "auto", LyricsText("third"))

        assertEquals("first", store().cached(song, "auto")?.value)
        assertEquals(LyricsText("second", "romaji"), store.cached(song, "custom"))
        assertNull(store.cached(song, "something else"))

        store.clearCache(song)
        assertNull(store.cached(song, "auto"))
        assertNull(store.cached(song, "custom"))
        assertEquals("third", store.cached(other, "auto")?.value)

        store.clearCache()
        assertNull(store.cached(other, "auto"))
    }
}
