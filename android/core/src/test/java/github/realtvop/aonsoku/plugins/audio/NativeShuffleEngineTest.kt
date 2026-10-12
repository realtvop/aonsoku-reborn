package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeShuffleEngineTest {
    private val engine = NativeShuffleEngine()

    private fun createSong(id: String): QueueSong {
        return QueueSong(
            id = id,
            title = "Title $id",
            artist = "Artist",
            artistId = null,
            album = "Album",
            albumId = null,
            duration = 100.0,
            coverArtId = null,
            streamUrl = "http://url",
            cachedFileUri = null
        )
    }

    @Test
    fun testShuffleEmptyHistory() {
        val songs = listOf(createSong("1"), createSong("2"), createSong("3"))
        val shuffled = engine.shuffleWithGapAvoidance(songs, emptyList())
        assertEquals(3, shuffled.size)
        assertTrue(shuffled.containsAll(songs))
    }

    @Test
    fun testShuffleWithHistoryGapAvoidance() {
        val songs = listOf(createSong("1"), createSong("2"), createSong("3"))
        // If history contains "2", it should put "2" in recent (end of list) and fresh ones "1", "3" in front
        val shuffled = engine.shuffleWithGapAvoidance(songs, listOf("2"))
        assertEquals(3, shuffled.size)
        // "2" should be the last element since it was in history
        assertEquals("2", shuffled.last().id)
    }

    @Test
    fun testPushToHistory() {
        val history = listOf("1", "2")
        val nextHistory = engine.pushToHistory(history, "3", 3)
        assertEquals(listOf("1", "2", "3"), nextHistory)

        val overflowHistory = engine.pushToHistory(nextHistory, "4", 3)
        assertEquals(listOf("2", "3", "4"), overflowHistory)
    }
}
