package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeQueueEngineUserQueueTest {
    private class Recorder : NativeQueueEngineDelegate {
        val loaded = mutableListOf<String>()
        val advances = mutableListOf<QueueAdvanceReason>()
        val contentChanges = mutableListOf<String>()

        override fun queueEngineLoadSong(
            engine: NativeQueueEngine,
            song: QueueSong,
            autoplay: Boolean,
            startTime: Double?,
        ) {
            loaded += song.id
        }

        override fun queueEngineDidAdvanceTo(
            engine: NativeQueueEngine,
            index: Int,
            songId: String,
            reason: QueueAdvanceReason,
        ) {
            advances += reason
        }

        override fun queueEngineDidChangeContents(engine: NativeQueueEngine, reason: String) {
            contentChanges += reason
        }

        override fun queueEngineDidExhaustQueue(engine: NativeQueueEngine) = Unit

        override fun queueEngineSeekToStart(engine: NativeQueueEngine, song: QueueSong) = Unit
    }

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

    private fun engine(recorder: Recorder): NativeQueueEngine = NativeQueueEngine().apply {
        delegate = recorder
        setContextQueue(listOf(song("c1"), song("c2"), song("c3")), 0, true, null)
        addToUserQueue(listOf(song("u1"), song("u2"), song("u3")), "last")
    }

    @Test
    fun jumpingIntoTheUserQueueKeepsSkippedSongsAsHistory() {
        val recorder = Recorder()
        val engine = engine(recorder)

        engine.playUserQueueAt(1)

        assertTrue(engine.isInUserQueue)
        assertEquals("u2", engine.currentSong?.id)
        assertEquals(listOf("u2", "u3"), engine.userQueue.map { it.id })
        assertEquals(listOf("u1"), engine.playedUserQueueHistory.map { it.id })
        assertEquals("u2", recorder.loaded.last())
        assertEquals(QueueAdvanceReason.SKIP, recorder.advances.last())
        assertEquals(0, engine.currentIndex)
    }

    @Test
    fun jumpingFurtherWhilePlayingTheUserQueueConsumesTheCurrentSong() {
        val recorder = Recorder()
        val engine = engine(recorder)
        engine.skipToNext()
        assertEquals("u1", engine.currentSong?.id)

        engine.playUserQueueAt(2)

        assertEquals("u3", engine.currentSong?.id)
        assertEquals(listOf("u3"), engine.userQueue.map { it.id })
        assertEquals(listOf("u1", "u2"), engine.playedUserQueueHistory.map { it.id })

        engine.skipToPrevious(0.0)
        assertEquals("u2", engine.currentSong?.id)
    }

    @Test
    fun jumpingToTheSongThatIsAlreadyPlayingDoesNothing() {
        val recorder = Recorder()
        val engine = engine(recorder)
        engine.skipToNext()
        val loadsBefore = recorder.loaded.size

        engine.playUserQueueAt(0)
        engine.playUserQueueAt(7)
        engine.playUserQueueAt(-1)

        assertEquals(loadsBefore, recorder.loaded.size)
        assertEquals("u1", engine.currentSong?.id)
    }

    @Test
    fun reordersUpcomingUserSongs() {
        val recorder = Recorder()
        val engine = engine(recorder)

        engine.reorderUserQueue(0, 2)

        assertEquals(listOf("u2", "u3", "u1"), engine.userQueue.map { it.id })
        assertEquals("queue-edit", recorder.contentChanges.last())
        assertEquals("c1", engine.currentSong?.id)
        assertFalse(engine.isInUserQueue)
    }

    @Test
    fun neverMovesTheUserSongThatIsPlaying() {
        val recorder = Recorder()
        val engine = engine(recorder)
        engine.skipToNext()
        val changesBefore = recorder.contentChanges.size

        engine.reorderUserQueue(0, 2)
        engine.reorderUserQueue(2, 0)
        assertEquals(listOf("u1", "u2", "u3"), engine.userQueue.map { it.id })
        assertEquals(changesBefore, recorder.contentChanges.size)

        engine.reorderUserQueue(2, 1)
        assertEquals(listOf("u1", "u3", "u2"), engine.userQueue.map { it.id })
        assertEquals("u1", engine.currentSong?.id)
    }

    @Test
    fun ignoresOutOfRangeReorders() {
        val recorder = Recorder()
        val engine = engine(recorder)
        val changesBefore = recorder.contentChanges.size

        engine.reorderUserQueue(1, 1)
        engine.reorderUserQueue(-1, 2)
        engine.reorderUserQueue(0, 3)

        assertEquals(listOf("u1", "u2", "u3"), engine.userQueue.map { it.id })
        assertEquals(changesBefore, recorder.contentChanges.size)
    }
}
