package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeQueueEngineShuffleTest {
    private fun song(id: String) = QueueSong(
        id = id,
        title = "Title $id",
        artist = "Artist",
        artistId = null,
        album = "Album",
        albumId = null,
        duration = 100.0,
        coverArtId = null,
        streamUrl = "aonsoku-media://stream?id=$id",
        cachedFileUri = null,
    )

    private fun songs(prefix: String, count: Int) = (1..count).map { song("$prefix$it") }

    private fun List<QueueSong>.ids() = map { it.id }

    @Test
    fun `shuffle is enabled even when a single context song is left`() {
        val engine = NativeQueueEngine()
        engine.setContextQueue(listOf(song("c1")), 0, true, null)

        engine.setShuffleActive(true)

        assertTrue(engine.isShuffleActive)
        assertEquals(listOf("c1"), engine.contextSongs.ids())

        engine.setShuffleActive(false)

        assertFalse(engine.isShuffleActive)
        assertEquals(listOf("c1"), engine.contextSongs.ids())
        assertEquals("c1", engine.currentSong?.id)
    }

    @Test
    fun `shuffle keeps played context songs and the current one in place`() {
        val engine = NativeQueueEngine()
        engine.setContextQueue(songs("c", 8), 2, true, null)

        repeat(10) {
            engine.setShuffleActive(true)

            assertEquals(listOf("c1", "c2", "c3"), engine.contextSongs.take(3).ids())
            assertEquals(songs("c", 8).ids().sorted(), engine.contextSongs.ids().sorted())
            assertEquals("c3", engine.currentSong?.id)

            engine.setShuffleActive(false)

            assertEquals(songs("c", 8).ids(), engine.contextSongs.ids())
            assertEquals(2, engine.currentIndex)
        }
    }

    @Test
    fun `shuffle never moves the song playing from the user queue`() {
        val engine = NativeQueueEngine()
        engine.setContextQueue(songs("c", 3), 0, true, null)
        engine.addToUserQueue(songs("u", 6), "last")
        engine.skipToNext()
        assertTrue(engine.isInUserQueue)

        repeat(10) {
            engine.setShuffleActive(true)

            assertEquals("u1", engine.currentSong?.id)
            assertEquals(songs("u", 6).ids().sorted(), engine.userQueue.ids().sorted())

            engine.setShuffleActive(false)

            assertEquals(songs("u", 6).ids(), engine.userQueue.ids())
            assertEquals("u1", engine.currentSong?.id)
        }
    }

    @Test
    fun `unshuffle keeps the context position while a queued song plays`() {
        val engine = NativeQueueEngine()
        engine.setContextQueue(songs("c", 6), 1, true, null)
        engine.addToUserQueue(listOf(song("u1")), "last")
        engine.skipToNext()
        engine.setShuffleActive(true)

        engine.setShuffleActive(false)

        assertEquals(songs("c", 6).ids(), engine.contextSongs.ids())
        assertEquals(1, engine.currentIndex)
        assertEquals("u1", engine.currentSong?.id)
    }

    @Test
    fun `unshuffle does not bring back queued songs that were already played`() {
        val engine = NativeQueueEngine()
        engine.setContextQueue(songs("c", 3), 0, true, null)
        engine.addToUserQueue(songs("u", 5), "last")
        engine.setShuffleActive(true)

        // Play two of the shuffled queued songs.
        engine.skipToNext()
        val firstPlayed = engine.currentSong!!.id
        engine.skipToNext()
        val nowPlaying = engine.currentSong!!.id

        engine.setShuffleActive(false)

        assertEquals(nowPlaying, engine.currentSong?.id)
        assertFalse(firstPlayed in engine.userQueue.ids())
        val expectedPending = songs("u", 5).ids().filter { it != firstPlayed && it != nowPlaying }
        assertEquals(listOf(nowPlaying) + expectedPending, engine.userQueue.ids())
    }

    @Test
    fun `unshuffle keeps songs queued while shuffling`() {
        val engine = NativeQueueEngine()
        engine.setContextQueue(songs("c", 3), 0, true, null)
        engine.addToUserQueue(songs("u", 4), "last")
        engine.setShuffleActive(true)
        engine.addToUserQueue(listOf(song("next")), "next")
        engine.addToUserQueue(listOf(song("last")), "last")

        engine.setShuffleActive(false)

        assertEquals(listOf("next", "u1", "u2", "u3", "u4", "last"), engine.userQueue.ids())
    }

    @Test
    fun `removing a queued song while shuffling keeps it removed`() {
        val engine = NativeQueueEngine()
        engine.setContextQueue(songs("c", 3), 0, true, null)
        engine.addToUserQueue(songs("u", 4), "last")
        engine.setShuffleActive(true)
        val removed = engine.userQueue[1].id
        engine.removeFromUserQueue(listOf(1))

        engine.setShuffleActive(false)

        assertEquals(songs("u", 4).ids().filter { it != removed }, engine.userQueue.ids())
    }
}
