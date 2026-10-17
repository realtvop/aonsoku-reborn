package github.realtvop.aonsoku.data.offline

import github.realtvop.aonsoku.plugins.audio.AudioCacheSource
import github.realtvop.aonsoku.plugins.audio.CachedAudio
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OfflineRulesTest {
    private fun audio(
        id: String,
        source: AudioCacheSource = AudioCacheSource.Explicit,
        triggers: List<String> = emptyList(),
        removed: Boolean = false,
    ) = CachedAudio(id, source, triggers, sizeBytes = 1, cachedAt = 0, lastAccessedAt = 0, removedFromServer = removed)

    @Test
    fun aSongCarriesEveryRuleThatMatchesIt() {
        val wanted = SmartDownloads.wanted(
            favoriteSongs = listOf("a", "b", "a", ""),
            playlistSongs = listOf("b", "c"),
        )

        assertEquals(
            mapOf(
                "a" to listOf("favorite"),
                "b" to listOf("favorite", "playlist"),
                "c" to listOf("playlist"),
            ),
            wanted,
        )
        assertEquals(emptyMap<String, List<String>>(), SmartDownloads.wanted(emptyList(), emptyList()))
    }

    @Test
    fun songsOfAPlaylistThatCouldNotBeReadAreNotLetGo() {
        val cached = listOf(
            audio("kept", AudioCacheSource.Smart, listOf("playlist")),
            audio("both", AudioCacheSource.Smart, listOf("favorite", "playlist")),
            audio("favorite-only", AudioCacheSource.Smart, listOf("favorite")),
            audio("mine", AudioCacheSource.Explicit),
        )

        val wanted = SmartDownloads.wanted(
            favoriteSongs = listOf("both"),
            playlistSongs = listOf("read"),
            playlistsKnown = false,
            cached = cached,
        )

        assertEquals(
            mapOf(
                "both" to listOf("favorite", "playlist"),
                "read" to listOf("playlist"),
                "kept" to listOf("playlist"),
            ),
            wanted,
        )
        // With every playlist read, what they no longer hold is let go.
        assertEquals(
            setOf("both", "read"),
            SmartDownloads.wanted(listOf("both"), listOf("read"), playlistsKnown = true, cached = cached).keys,
        )
    }

    @Test
    fun cachedSongsTheLibraryNoLongerListsAreMarked() {
        val cached = listOf(audio("a"), audio("b"), audio("c"), audio("gone"))

        assertEquals(setOf("gone"), missingFromLibrary(cached, existing = setOf("a", "b", "c")))
        assertEquals(emptySet<String>(), missingFromLibrary(cached, existing = setOf("a", "b", "c", "gone")))
        assertEquals(emptySet<String>(), missingFromLibrary(emptyList(), existing = emptySet()))
    }

    @Test
    fun noVerdictIsPassedWhenMostSongsWouldBeMarkedAtOnce() {
        val cached = listOf(audio("a"), audio("b"), audio("c"), audio("d"))

        // Half of them may go at once; more looks like a library that is not all there.
        assertEquals(setOf("c", "d"), missingFromLibrary(cached, existing = setOf("a", "b")))
        assertNull(missingFromLibrary(cached, existing = setOf("a")))
        assertNull(missingFromLibrary(cached, existing = emptySet()))
    }

    @Test
    fun songsMarkedBeforeDoNotCountAsNewlyGone() {
        val cached = listOf(
            audio("a"),
            audio("old-1", removed = true),
            audio("old-2", removed = true),
            audio("new"),
        )

        // Three of four are missing, but only one of them since the last look.
        assertEquals(setOf("old-1", "old-2", "new"), missingFromLibrary(cached, existing = setOf("a")))
        // One that came back is simply no longer among the missing.
        assertEquals(setOf("old-2"), missingFromLibrary(cached, existing = setOf("a", "old-1", "new")))
    }
}
