package github.realtvop.aonsoku.ui.shell

import github.realtvop.aonsoku.data.offline.CoverSyncProgress
import github.realtvop.aonsoku.plugins.data.LibrarySyncState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SyncStatusTest {
    private fun state(phase: String, tier: String? = null, syncing: Boolean = false, progress: Int = 0) =
        LibrarySyncState(phase, tier, syncing, progress, processedItems = 0, totalItems = 0)

    private fun statuses(phase: String, tier: String?) =
        SyncTier.entries.map { tierStatus(it, phase, SyncTier.of(tier)) }

    @Test
    fun tiersBeforeTheRunningOneAreDoneAndThoseAfterWait() {
        assertEquals(
            listOf(TierStatus.Running, TierStatus.Pending, TierStatus.Pending),
            statuses("playlists", "t1"),
        )
        assertEquals(
            listOf(TierStatus.Done, TierStatus.Running, TierStatus.Pending),
            statuses("albums", "t2"),
        )
        assertEquals(
            listOf(TierStatus.Done, TierStatus.Done, TierStatus.Running),
            statuses("songs", "t3"),
        )
    }

    @Test
    fun aSyncThatEndedShowsNoTierAsRunning() {
        assertEquals(List(3) { TierStatus.Done }, statuses("done", null))
        assertEquals(List(3) { TierStatus.Done }, statuses("cancelled", null))
        // Nothing ran yet in this session.
        assertEquals(List(3) { TierStatus.Pending }, statuses("idle", null))
    }

    @Test
    fun anErrorIsShownOnTheTierItHappenedIn() {
        assertEquals(
            listOf(TierStatus.Done, TierStatus.Error, TierStatus.Pending),
            statuses("error", "t2"),
        )
        // The engine does not always say where it failed.
        assertEquals(List(3) { TierStatus.Pending }, statuses("error", null))
    }

    @Test
    fun aTierAdvancesWithThePhasesItIsMadeOf() {
        assertEquals(0, SyncTier.Essentials.progress("genres", 0))
        assertEquals(10, SyncTier.Essentials.progress("genres", 50))
        assertEquals(20, SyncTier.Essentials.progress("playlists", 0))
        assertEquals(45, SyncTier.Essentials.progress("playlists", 50))
        assertEquals(70, SyncTier.Essentials.progress("favorites", 0))
        assertEquals(100, SyncTier.Essentials.progress("favorites", 100))
        assertEquals(65, SyncTier.Skeleton.progress("albums", 50))
        assertEquals(40, SyncTier.Songs.progress("songs", 40))
        // A phase of another tier says nothing about this one.
        assertEquals(0, SyncTier.Songs.progress("albums", 80))
        assertEquals(100, SyncTier.Songs.progress("songs", 250))
    }

    @Test
    fun theAccountBadgeTellsTheMostPressingThing() {
        val cover = CoverSyncProgress(processed = 1, total = 4)

        assertEquals(SyncBadge.Offline, syncBadge(online = false, state("songs", "t3", syncing = true), cover))
        assertEquals(SyncBadge.Error, syncBadge(online = true, state("error"), cover))
        assertEquals(SyncBadge.Syncing, syncBadge(online = true, state("songs", "t3", syncing = true), null))
        // The images are still being fetched after the library is done.
        assertEquals(SyncBadge.Syncing, syncBadge(online = true, state("done"), cover))
        assertEquals(SyncBadge.Done, syncBadge(online = true, state("done"), null))
        assertNull(syncBadge(online = true, state("idle"), null))
        assertNull(syncBadge(online = true, state("cancelled"), null))
    }

    @Test
    fun coverSyncProgressIsAPercentage() {
        assertEquals(0, CoverSyncProgress(0, 0).percent)
        assertEquals(25, CoverSyncProgress(1, 4).percent)
        assertEquals(100, CoverSyncProgress(4, 4).percent)
    }
}
