package github.realtvop.aonsoku.plugins.data

import github.realtvop.aonsoku.plugins.data.sync.SyncTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncTierTest {
    @Test
    fun t1FreshWindowIs5Minutes() {
        assertEquals(5 * 60 * 1000L, SyncTier.T1.freshWindowMs)
    }

    @Test
    fun t2FreshWindowIs30Minutes() {
        assertEquals(30 * 60 * 1000L, SyncTier.T2.freshWindowMs)
    }

    @Test
    fun t3FreshWindowIs2Hours() {
        assertEquals(2 * 60 * 60 * 1000L, SyncTier.T3.freshWindowMs)
    }

    @Test
    fun tiersAreInIncreasingOrder() {
        assertTrue(SyncTier.T1.freshWindowMs < SyncTier.T2.freshWindowMs)
        assertTrue(SyncTier.T2.freshWindowMs < SyncTier.T3.freshWindowMs)
    }
}
