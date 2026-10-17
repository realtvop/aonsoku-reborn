package github.realtvop.aonsoku.plugins.audio

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeQueueEngineTest {
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
    fun testSetContextQueue() {
        val engine = NativeQueueEngine()
        var loadedSong: QueueSong? = null
        engine.delegate = object : NativeQueueEngineDelegate {
            override fun queueEngineLoadSong(engine: NativeQueueEngine, song: QueueSong, autoplay: Boolean, startTime: Double?) {
                loadedSong = song
            }
            override fun queueEngineDidAdvanceTo(engine: NativeQueueEngine, index: Int, songId: String, reason: QueueAdvanceReason) {}
            override fun queueEngineDidChangeContents(engine: NativeQueueEngine, reason: String) {}
            override fun queueEngineDidExhaustQueue(engine: NativeQueueEngine) {}
            override fun queueEngineSeekToStart(engine: NativeQueueEngine, song: QueueSong) {}
        }

        val songs = listOf(createSong("1"), createSong("2"))
        engine.setContextQueue(songs, 0, true, 0.0)

        assertEquals(2, engine.contextSongs.size)
        assertEquals(0, engine.currentIndex)
        assertEquals("1", engine.currentSong?.id)
        assertNotNull(loadedSong)
        assertEquals("1", loadedSong?.id)
    }

    @Test
    fun testSkipNextAndPrev() {
        val engine = NativeQueueEngine()
        val songs = listOf(createSong("1"), createSong("2"), createSong("3"))
        engine.setContextQueue(songs, 0, false, null)

        // Skip to next
        engine.skipToNext()
        assertEquals(1, engine.currentIndex)
        assertEquals("2", engine.currentSong?.id)

        // Skip to prev (currentTime < threshold)
        engine.skipToPrevious(0.0)
        assertEquals(0, engine.currentIndex)
        assertEquals("1", engine.currentSong?.id)
    }

    @Test
    fun testUserQueueFlow() {
        val engine = NativeQueueEngine()
        val songs = listOf(createSong("1"), createSong("2"))
        engine.setContextQueue(songs, 0, false, null)

        val userSongs = listOf(createSong("A"), createSong("B"))
        engine.addToUserQueue(userSongs, "next")

        assertEquals(2, engine.userQueue.size)
        assertEquals("A", engine.userQueue[0].id)

        // Skip next should play from user queue
        engine.skipToNext()
        assertTrue(engine.isInUserQueue)
        assertEquals("A", engine.currentSong?.id)
        assertEquals(2, engine.userQueue.size) // A is active, still in userQueue

        engine.skipToNext()
        assertTrue(engine.isInUserQueue)
        assertEquals("B", engine.currentSong?.id)
        assertEquals(1, engine.userQueue.size) // A is consumed, B is active

        engine.skipToNext()
        assertFalse(engine.isInUserQueue)
        assertEquals("2", engine.currentSong?.id) // Context queue resumes
        assertEquals(0, engine.userQueue.size) // B is consumed, userQueue empty
    }

    @Test
    fun testReorderAndRemove() {
        val engine = NativeQueueEngine()
        val songs = listOf(createSong("1"), createSong("2"), createSong("3"))
        engine.setContextQueue(songs, 0, false, null)

        engine.reorderContextQueue(0, 2)
        assertEquals("2", engine.contextSongs[0].id)
        assertEquals("3", engine.contextSongs[1].id)
        assertEquals("1", engine.contextSongs[2].id)

        engine.addToUserQueue(listOf(createSong("A"), createSong("B")), "last")
        engine.removeFromUserQueue(listOf(0)) // Removes A
        assertEquals(1, engine.userQueue.size)
        assertEquals("B", engine.userQueue[0].id)
    }

    @Test
    fun testStateRestoration() {
        val engine = NativeQueueEngine()
        val songs = listOf(createSong("1"), createSong("2"))
        engine.setContextQueue(songs, 0, false, null)

        val state = PlaybackPersistState.from(engine, 10.5)
        val json = state.toJson()

        val newEngine = NativeQueueEngine()
        val restoredState = PlaybackPersistState.fromJson(json)
        newEngine.restoreState(restoredState)

        assertTrue(newEngine.isRestored)
        assertEquals(2, newEngine.contextSongs.size)
        assertEquals(0, newEngine.currentIndex)
        assertEquals("1", newEngine.currentSong?.id)

        val fullState = newEngine.getFullState(10.5, 100.0, false)
        assertEquals("1", fullState.getString("currentSongId"))
        assertEquals(10.5, fullState.getDouble("currentTime"), 0.001)
    }
}
