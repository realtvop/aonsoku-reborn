package github.realtvop.aonsoku.player

import github.realtvop.aonsoku.plugins.audio.QueueSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QueuePlannerTest {
    private fun song(id: String) = QueueSong(
        id = id,
        title = "Song $id",
        artist = "Artist",
        artistId = null,
        album = "Album",
        albumId = null,
        duration = 180.0,
        coverArtId = null,
        streamUrl = "aonsoku-media://stream?id=$id",
        cachedFileUri = null,
    )

    private fun songs(vararg ids: String) = ids.map(::song)

    private fun List<QueueSong>.ids() = map { it.id }

    @Test
    fun `queue starts at the selected song and drops earlier ones`() {
        val queue = QueuePlanner.build(songs("a", "b", "c", "d"), 2, repeatAll = false, shuffle = false)

        assertEquals(listOf("c", "d"), queue.ids())
    }

    @Test
    fun `repeat all rotates earlier songs to the end`() {
        val queue = QueuePlanner.build(songs("a", "b", "c", "d"), 2, repeatAll = true, shuffle = false)

        assertEquals(listOf("c", "d", "a", "b"), queue.ids())
    }

    @Test
    fun `out of range start index is clamped`() {
        assertEquals(
            listOf("c"),
            QueuePlanner.build(songs("a", "b", "c"), 9, repeatAll = false, shuffle = false).ids(),
        )
        assertEquals(
            listOf("a", "b", "c"),
            QueuePlanner.build(songs("a", "b", "c"), -3, repeatAll = false, shuffle = false).ids(),
        )
        assertTrue(QueuePlanner.build(emptyList(), 0, repeatAll = true, shuffle = true).isEmpty())
    }

    @Test
    fun `shuffle keeps the start song first and every other song once`() {
        val source = songs("a", "b", "c", "d", "e", "f", "g", "h")

        repeat(20) {
            val queue = QueuePlanner.build(source, 3, repeatAll = true, shuffle = true)

            assertEquals("d", queue.first().id)
            assertEquals(source.ids().sorted(), queue.ids().sorted())
        }
    }

    @Test
    fun `shuffle without repeat only covers the songs from the start`() {
        val queue = QueuePlanner.build(songs("a", "b", "c", "d"), 2, repeatAll = false, shuffle = true)

        assertEquals("c", queue.first().id)
        assertEquals(listOf("c", "d"), queue.ids().sorted())
    }

    @Test
    fun `replacement asks only while playing with manually queued songs left`() {
        assertTrue(QueuePlanner.shouldConfirmReplacement(true, userQueueSize = 2, isInUserQueue = false))
        assertTrue(QueuePlanner.shouldConfirmReplacement(true, userQueueSize = 2, isInUserQueue = true))
        // The song playing from the user queue is not a pending one.
        assertFalse(QueuePlanner.shouldConfirmReplacement(true, userQueueSize = 1, isInUserQueue = true))
        assertFalse(QueuePlanner.shouldConfirmReplacement(true, userQueueSize = 0, isInUserQueue = false))
        assertFalse(QueuePlanner.shouldConfirmReplacement(false, userQueueSize = 3, isInUserQueue = false))
    }

    @Test
    fun `play next keeps the selection order from the chosen song`() {
        val next = QueuePlanner.replacementPlayNext(songs("a", "b", "c"), 1, shuffle = false)

        assertEquals(listOf("b", "c"), next.ids())
    }

    @Test
    fun `shuffled play next keeps every selected song`() {
        val next = QueuePlanner.replacementPlayNext(songs("a", "b", "c", "d"), 2, shuffle = true)

        assertEquals(listOf("a", "b", "c", "d"), next.ids().sorted())
    }

    @Test
    fun `removing an earlier context song shifts the current index`() {
        val (remaining, index) = QueuePlanner.removeFromContext(
            songs("a", "b", "c"),
            currentIndex = 2,
            isInUserQueue = false,
            removedIndex = 0,
        )!!

        assertEquals(listOf("b", "c"), remaining.ids())
        assertEquals(1, index)
    }

    @Test
    fun `removing a later context song keeps the current index`() {
        val (remaining, index) = QueuePlanner.removeFromContext(
            songs("a", "b", "c"),
            currentIndex = 0,
            isInUserQueue = false,
            removedIndex = 2,
        )!!

        assertEquals(listOf("a", "b"), remaining.ids())
        assertEquals(0, index)
    }

    @Test
    fun `removing the current context song moves to its successor`() {
        val (remaining, index) = QueuePlanner.removeFromContext(
            songs("a", "b", "c"),
            currentIndex = 1,
            isInUserQueue = false,
            removedIndex = 1,
        )!!

        assertEquals(listOf("a", "c"), remaining.ids())
        assertEquals(1, index)

        val (lastRemoved, lastIndex) = QueuePlanner.removeFromContext(
            songs("a", "b", "c"),
            currentIndex = 2,
            isInUserQueue = false,
            removedIndex = 2,
        )!!

        assertEquals(listOf("a", "b"), lastRemoved.ids())
        assertEquals(1, lastIndex)
    }

    @Test
    fun `removing the resume position while a queued song plays keeps what follows`() {
        val (remaining, index) = QueuePlanner.removeFromContext(
            songs("a", "b", "c"),
            currentIndex = 1,
            isInUserQueue = true,
            removedIndex = 1,
        )!!

        assertEquals(listOf("a", "c"), remaining.ids())
        // The context resumes after index 0, which is now "c".
        assertEquals(0, index)
    }

    @Test
    fun `the last context song and invalid indexes cannot be removed`() {
        assertNull(QueuePlanner.removeFromContext(songs("a"), 0, isInUserQueue = false, removedIndex = 0))
        assertNull(QueuePlanner.removeFromContext(songs("a", "b"), 0, isInUserQueue = false, removedIndex = 5))
    }

    @Test
    fun `start history is capped relative to the queue size`() {
        var history = emptyList<String>()
        repeat(30) { history = QueuePlanner.pushStartHistory(history, "song-$it", queueSize = 20) }

        assertEquals(10, history.size)
        assertTrue("song-29" in history)
    }
}
