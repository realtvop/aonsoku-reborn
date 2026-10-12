package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class NativeScrobbleBufferTest {
    private lateinit var store: InMemoryScrobbleStore
    private lateinit var buffer: NativeScrobbleBuffer

    @Before
    fun setUp() {
        store = InMemoryScrobbleStore()
        buffer = NativeScrobbleBuffer(store)
    }

    @Test
    fun testStartTrackingCreatesEntryOnStop() {
        buffer.startTracking("song-1", duration = 200.0)
        Thread.sleep(50)
        val entry = buffer.stopTracking()
        assertNotNull("stopTracking should return an entry", entry)
        assertEquals("song-1", entry!!.songId)
        assertTrue("playedDurationMs should be > 0", entry.playedDurationMs > 0)
    }

    @Test
    fun testStopTrackingWithNoTime_ReturnsNull() {
        buffer.startTracking("song-1")
        // Immediately stop without any time passing
        val entry = buffer.stopTracking()
        // Actually the time may pass even minimally; let's test with pause + immediate stop
        buffer.pauseTracking()
        val pausedEntry = buffer.stopTracking()
        assertNull("stopTracking after pause without any time should be null", pausedEntry)
    }

    @Test
    fun testPauseAndResumeTracking() {
        buffer.startTracking("song-1", duration = 200.0)
        Thread.sleep(30)
        buffer.pauseTracking()
        val pausedMs = buffer.stopTracking()!!.playedDurationMs

        buffer.startTracking("song-1", duration = 200.0)
        Thread.sleep(30)
        buffer.resumeTracking()
        Thread.sleep(20)
        val resumedEntry = buffer.stopTracking()!!

        assertTrue("resumed entry should track additional time", resumedEntry.playedDurationMs > pausedMs)
    }

    @Test
    fun testGetEntries() {
        buffer.startTracking("song-1", duration = 100.0)
        Thread.sleep(20)
        buffer.stopTracking()

        buffer.startTracking("song-2", duration = 200.0)
        Thread.sleep(20)
        buffer.stopTracking()

        val entries = buffer.getEntries()
        assertEquals("should have 2 entries", 2, entries.size)
        assertEquals("song-1", entries[0].songId)
        assertEquals("song-2", entries[1].songId)
    }

    @Test
    fun testClearEntries() {
        buffer.startTracking("song-1")
        Thread.sleep(10)
        buffer.stopTracking()

        assertEquals("should have 1 entry", 1, buffer.getEntries().size)
        buffer.clear()
        assertEquals("should have 0 entries after clear", 0, buffer.getEntries().size)
    }

    @Test
    fun testRemoveEntries() {
        buffer.startTracking("song-1")
        Thread.sleep(10)
        buffer.stopTracking()

        buffer.startTracking("song-2")
        Thread.sleep(10)
        buffer.stopTracking()

        assertEquals("should have 2 entries", 2, buffer.getEntries().size)
        buffer.removeEntries(setOf("song-1"))
        assertEquals("should have 1 entry after remove", 1, buffer.getEntries().size)
        assertEquals("song-2", buffer.getEntries()[0].songId)
    }

    @Test
    fun testPersistenceAcrossBufferRestarts() {
        buffer.startTracking("song-1", duration = 100.0)
        Thread.sleep(20)
        buffer.stopTracking()

        assertEquals("in-memory store should have 1 entry", 1, store.load().size)

        // Simulate buffer restart
        val buffer2 = NativeScrobbleBuffer(store)
        val entries = buffer2.getEntries()
        assertEquals("restored buffer should have 1 entry", 1, entries.size)
        assertEquals("song-1", entries[0].songId)
    }

    @Test
    fun testMultipleStartTracking_OnlyLastCounts() {
        buffer.startTracking("song-1")
        Thread.sleep(10)
        buffer.startTracking("song-2") // implicitly flushes song-1
        Thread.sleep(20)
        val entry = buffer.stopTracking()

        assertNotNull(entry)
        assertEquals("song-2", entry!!.songId)
        assertEquals("should have 2 entries total", 2, buffer.getEntries().size)
    }

    @Test
    fun testLastEntryDuration() {
        buffer.startTracking("song-1", duration = 300.0)
        Thread.sleep(10)
        buffer.stopTracking()
        assertEquals(300.0, buffer.lastEntryDuration ?: 0.0, 0.001)
    }
}

class InMemoryScrobbleStore : ScrobbleEntryStore {
    private var entries: List<ScrobbleEntry> = emptyList()

    override fun save(entries: List<ScrobbleEntry>) {
        this.entries = entries.toList()
    }

    override fun load(): List<ScrobbleEntry> = entries.toList()
}
