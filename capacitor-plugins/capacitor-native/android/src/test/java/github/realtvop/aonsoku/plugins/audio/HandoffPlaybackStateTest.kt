package github.realtvop.aonsoku.plugins.audio

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HandoffPlaybackStateTest {
    private fun song(id: String) = QueueSong(id, id, "artist", null, "album", null, 300.0, null, "https://stream/$id", null)
    private fun snapshot() = JSONObject()
        .put("mediaKind", "song").put("songId", "u")
        .put("contextQueue", JSONArray(listOf("a", "b"))).put("contextIndex", 1)
        .put("userQueue", JSONArray(listOf("u", "v"))).put("inUserQueue", true)
        .put("restorePrevious", JSONArray(listOf("p")))
        .put("shuffle", true).put("repeat", "all").put("progressSeconds", 51.0)
        .put("sourceId", "playlist:source").put("sourceName", "source queue")

    @Test fun preservesUserSongHistoryAndShuffledOrder() {
        val state = handoffPlaybackState(snapshot(), listOf("a", "b", "u", "v", "p").map(::song))
        val engine = NativeQueueEngine()
        engine.restoreState(state)
        assertEquals("u", engine.currentSong?.id)
        assertEquals(listOf("a", "b"), engine.contextSongs.map { it.id })
        assertEquals(listOf("u", "v"), engine.userQueue.map { it.id })
        assertEquals(listOf("p"), engine.playedUserQueueHistory.map { it.id })
        assertTrue(engine.isShuffleActive)
        assertEquals(LoopState.ALL, engine.loopState)
        assertEquals(51.0, state.currentTime, 0.0)
        assertEquals(QueueSourceId("playlist", "source"), state.sourceId)
        engine.skipToNext()
        assertEquals("v", engine.currentSong?.id)
    }

    @Test fun preservesAnEmptyContextWhilePlayingUserQueue() {
        val state = handoffPlaybackState(snapshot().put("contextQueue", JSONArray()).put("contextIndex", JSONObject.NULL), listOf("u", "v", "p").map(::song))
        assertTrue(state.contextSongs.isEmpty())
        assertTrue(state.isInUserQueue)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsMissingQueueSongsRatherThanShiftingIndices() {
        handoffPlaybackState(snapshot(), listOf("a", "u", "v", "p").map(::song))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsAnInconsistentCurrentUserSong() {
        handoffPlaybackState(snapshot().put("songId", "v"), listOf("a", "b", "u", "v", "p").map(::song))
    }

    @Test fun supportsALegacySingleSongSnapshot() {
        val state = handoffPlaybackState(JSONObject().put("songId", "a"), listOf(song("a")))
        assertEquals(listOf("a"), state.contextSongs.map { it.id })
        assertFalse(state.isInUserQueue)
    }
}
