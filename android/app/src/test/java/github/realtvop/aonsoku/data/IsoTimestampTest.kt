package github.realtvop.aonsoku.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class IsoTimestampTest {
    @Test
    fun parsesUtcTimestampsWithAndWithoutFractions() {
        assertEquals(1_704_164_645_000L, parseIsoTimestamp("2024-01-02T03:04:05Z"))
        assertEquals(1_704_164_645_123L, parseIsoTimestamp("2024-01-02T03:04:05.123Z"))
        assertEquals(1_704_164_645_123L, parseIsoTimestamp("2024-01-02T03:04:05.123456789Z"))
        assertEquals(1_704_164_645_500L, parseIsoTimestamp("2024-01-02T03:04:05.5Z"))
    }

    @Test
    fun treatsMissingOffsetsAsUtc() {
        assertEquals(1_704_164_645_000L, parseIsoTimestamp("2024-01-02T03:04:05"))
        assertEquals(1_704_164_645_000L, parseIsoTimestamp(" 2024-01-02 03:04:05 "))
    }

    @Test
    fun appliesExplicitOffsets() {
        assertEquals(1_704_164_645_000L, parseIsoTimestamp("2024-01-02T11:04:05+08:00"))
        assertEquals(1_704_164_645_000L, parseIsoTimestamp("2024-01-01T22:04:05-0500"))
    }

    @Test
    fun rejectsMalformedValues() {
        assertNull(parseIsoTimestamp(null))
        assertNull(parseIsoTimestamp(""))
        assertNull(parseIsoTimestamp("yesterday"))
        assertNull(parseIsoTimestamp("2024-13-40T99:99:99Z"))
    }
}
