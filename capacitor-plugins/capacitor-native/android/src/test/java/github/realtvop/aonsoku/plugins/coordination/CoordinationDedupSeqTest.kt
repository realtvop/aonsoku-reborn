package github.realtvop.aonsoku.plugins.coordination

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// §9.1/§9.2 dedup + seq helper tests. These run as plain JUnit tests without
/// an Android Keystore or WebSocket stack.
class CoordinationDedupSeqTest {

    // --- CoordinationDedup ---------------------------------------------------

    @Test
    fun dedupMarksAndDetectsDuplicates() {
        val cache = CoordinationDedup(max = 3)
        assertFalse(cache.has("a"))
        cache.mark("a")
        assertTrue(cache.has("a"))
        assertFalse(cache.has("b"))
        cache.mark("b")
        assertTrue(cache.has("b"))
        assertEquals(2, cache.size())
    }

    @Test
    fun dedupEvictsOldestWhenFull() {
        val cache = CoordinationDedup(max = 2)
        cache.mark("a")
        cache.mark("b")
        assertTrue(cache.has("a"))
        assertTrue(cache.has("b"))
        // Adding a third entry evicts the oldest ("a").
        cache.mark("c")
        assertFalse("oldest entry should be evicted", cache.has("a"))
        assertTrue(cache.has("b"))
        assertTrue(cache.has("c"))
        assertEquals(2, cache.size())
    }

    @Test
    fun dedupMarkIsIdempotent() {
        val cache = CoordinationDedup(max = 5)
        cache.mark("x")
        cache.mark("x")
        assertEquals(1, cache.size())
    }

    @Test
    fun dedupClearResets() {
        val cache = CoordinationDedup(max = 5)
        cache.mark("a")
        cache.mark("b")
        cache.clear()
        assertEquals(0, cache.size())
        assertFalse(cache.has("a"))
    }

    // --- CoordinationSeqTracker ----------------------------------------------

    @Test
    fun seqTrackerOnlyIncreases() {
        val tracker = CoordinationSeqTracker()
        assertEquals(0L, tracker.get())
        tracker.observe(5L)
        assertEquals(5L, tracker.get())
        // A lower seq must not overwrite the high-water mark.
        tracker.observe(3L)
        assertEquals(5L, tracker.get())
        tracker.observe(10L)
        assertEquals(10L, tracker.get())
    }

    @Test
    fun seqTrackerIgnoresNull() {
        val tracker = CoordinationSeqTracker()
        tracker.observe(null)
        assertEquals(0L, tracker.get())
    }

    @Test
    fun seqTrackerResetReturnsToZero() {
        val tracker = CoordinationSeqTracker()
        tracker.observe(42L)
        tracker.reset()
        assertEquals(0L, tracker.get())
    }

    // --- envelope extraction helpers ----------------------------------------

    @Test
    fun extractSeqReturnsLongForNumber() {
        val env = JSONObject().put("seq", 7)
        assertEquals(7L, AonsokuNativeCoordinationPlugin.extractSeq(env))
    }

    @Test
    fun extractSeqReturnsNullWhenAbsent() {
        val env = JSONObject()
        assertNull(AonsokuNativeCoordinationPlugin.extractSeq(env))
    }

    @Test
    fun extractSeqParsesStringNumber() {
        val env = JSONObject().put("seq", "12")
        assertEquals(12L, AonsokuNativeCoordinationPlugin.extractSeq(env))
    }

    @Test
    fun extractMessageIdReturnsString() {
        val env = JSONObject().put("messageId", "abc-123")
        assertEquals("abc-123", AonsokuNativeCoordinationPlugin.extractMessageId(env))
    }

    @Test
    fun extractMessageIdReturnsNullWhenAbsent() {
        val env = JSONObject()
        assertNull(AonsokuNativeCoordinationPlugin.extractMessageId(env))
    }

    @Test
    fun extractTypeReturnsString() {
        val env = JSONObject().put("type", "command_ack")
        assertEquals("command_ack", AonsokuNativeCoordinationPlugin.extractType(env))
    }

    @Test
    fun extractTypeReturnsNullWhenAbsent() {
        val env = JSONObject()
        assertNull(AonsokuNativeCoordinationPlugin.extractType(env))
    }
}