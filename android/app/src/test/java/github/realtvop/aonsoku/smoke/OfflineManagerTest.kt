package github.realtvop.aonsoku.smoke

import android.app.Application
import kotlinx.coroutines.async
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.data.offline.CachedItemType
import github.realtvop.aonsoku.data.offline.PoolStats
import github.realtvop.aonsoku.plugins.audio.AudioCacheSource
import github.realtvop.aonsoku.settings.SmartDownloadRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Downloads, smart downloads, and the image cache on the real services,
 * against the fake server: what ends up on the device, and what goes again.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class OfflineManagerTest {
    @get:Rule
    val world = SmokeWorld()

    private val offline get() = world.graph.offline
    private val cached get() = offline.cached.value
    private val audioCache get() = world.graph.services.audioCache
    private val library get() = world.graph.services.library

    @Before
    fun serveWholeFiles() {
        world.server.throttleStreams = false
    }

    @Test
    fun changingPrimaryServerClearsThePreviousLibraryEvenWithTheSameCredentials() {
        signIn()
        val oldSong = song("al-2", "Harbor")
        offline.download(listOf(oldSong))
        world.waitUntil("the old server download") { oldSong.id in cached }
        val oldFile = audioCache.file(oldSong.id)!!
        val other = FakeSubsonicServer()
        other.start()
        try {
            assertTrue(world.await { world.graph.session.saveServerUrls(other.url, "") })
            assertEquals(other.url, world.graph.session.credentials?.serverUrl)
            assertNull(world.await { library.getSong(oldSong.id) })
            assertFalse(oldFile.exists())
            assertTrue(cached.isEmpty())
            world.graph.onServerChanged()
            world.waitUntil("the new library sync") { world.await { library.getSong(oldSong.id) } != null }
        } finally {
            other.shutdown()
        }
    }

    @Test
    fun anOldArtworkResponseCannotRepopulateTheCacheAfterSignOut() {
        signIn()
        world.server.holdArtwork = true
        world.server.requests.clear()
        val request = world.graph.scope.async {
            runCatching { library.downloadCoverImage("old-account-cover", "700") }
        }
        world.waitUntil("the old cover request to start") { world.server.requested("getCoverArt") }
        world.await { world.graph.signOut() }
        world.server.holdArtwork = false
        assertTrue(world.await { request.await() }.isFailure)
        assertNull(world.await { library.resolveCoverImage("old-account-cover") })
        assertEquals(0, world.await { library.getCoverCacheStats() }.count)
    }

    @Test
    fun aDownloadedSongBringsItsLyricsAndItsCover() {
        signIn()
        val lowTide = song("al-3", "Low Tide")

        offline.download(listOf(lowTide))

        world.waitUntil("the download") { cached[lowTide.id]?.source == AudioCacheSource.Explicit }
        val file = audioCache.file(lowTide.id)
        assertNotNull(file)
        assertTrue(offline.downloads.value.isEmpty())
        world.waitUntil("the pool to count it") {
            offline.pools.value.explicit == PoolStats(1, file!!.length())
        }
        world.waitUntil("the lyrics to come along") { world.await { library.getLyrics(lowTide.id) } != null }
        world.waitUntil("the cover to come along") { world.await { library.getCoverImageSize("al-al-3") } != null }
    }

    @Test
    fun anAlbumIsDownloadedSongBySongAndNoted() {
        signIn()
        val album = world.await { world.graph.library.albumDetails("al-1") }!!
        val songIds = album.song.orEmpty().map { it.id }.toSet()
        assertEquals(4, songIds.size)

        offline.downloadAlbum(album)
        world.waitUntil("the songs of the album") { cached.keys == songIds }

        val items = world.await { offline.items() }
        val note = items.single { it.type == CachedItemType.Album }
        assertEquals(listOf("Northern Lights", "Aurora Lane"), listOf(note.name, note.subtitle))
        val song = items.first { it.type == CachedItemType.Audio && it.name == "First Snow" }
        assertEquals("Aurora Lane", song.subtitle)
        assertEquals(AudioCacheSource.Explicit, song.source)

        // The note can go without the songs, and a song without the others.
        world.await { offline.remove(note) }
        world.await { offline.remove(song) }
        assertEquals(songIds - song.id, cached.keys)
        assertFalse(world.await { offline.items() }.any { it.type == CachedItemType.Album })
        assertNull(audioCache.file(song.id))
    }

    @Test
    fun aPlaylistAndAnArtistAreDownloadedAsTheirSongs() {
        signIn()
        val playlist = world.await { world.graph.library.playlistsNow() }.first { it.id == "pl-1" }
        val artist = world.await { world.graph.library.artists() }.first { it.name == "Cedar and Stone" }

        offline.downloadPlaylist(playlist)
        // "First Snow" is in the playlist twice and downloaded once.
        world.waitUntil("the songs of the playlist") {
            cached.keys == setOf("so-al-1-1", "so-al-2-1", "so-al-3-1")
        }
        assertTrue(world.await { offline.items() }.any { it.type == CachedItemType.Playlist && it.name == "Morning Mix" })

        offline.downloadArtist(artist)
        world.waitUntil("the songs of the artist") {
            cached.keys.containsAll(listOf("so-al-5-1", "so-al-5-2", "so-al-5-3"))
        }
        assertEquals(6, cached.size)
        assertTrue(cached.values.all { it.source == AudioCacheSource.Explicit })
    }

    @Test
    fun smartDownloadsFollowTheFavorites() {
        signIn()
        smartRules(SmartDownloadRules(enabled = true))

        world.waitUntil("the favorite songs") { cached.keys == setOf("so-al-1-1", "so-al-3-2") }
        assertTrue(cached.values.all { it.source == AudioCacheSource.Smart && it.triggers == listOf("favorite") })

        // A song that is no longer a favorite is let go, a new one is fetched.
        val undertow = song("al-3", "Undertow")
        val embers = song("al-5", "Embers")
        world.await { world.graph.library.setSongStarred(undertow, false) }
        world.await { world.graph.library.setSongStarred(embers, true) }
        world.waitUntil("the rules to be followed") { cached.keys == setOf("so-al-1-1", "so-al-5-2") }

        // What the user downloads is not the rules' to take away.
        offline.download(listOf(song("al-1", "First Snow")))
        world.waitUntil("the song to change hands") { cached["so-al-1-1"]?.source == AudioCacheSource.Explicit }
        smartRules(SmartDownloadRules(enabled = false))
        world.waitUntil("the smart downloads to go") { cached.keys == setOf("so-al-1-1") }
    }

    @Test
    fun songsOfFavoritePlaylistsAreKeptToo() {
        world.server.starredPlaylists += "pl-1"
        signIn()

        smartRules(SmartDownloadRules(enabled = true, favoriteSongs = false, favoritePlaylists = true))

        world.waitUntil("the songs of the favorite playlist") {
            cached.keys == setOf("so-al-1-1", "so-al-2-1", "so-al-3-1")
        }
        assertTrue(cached.values.all { it.triggers == listOf("playlist") })

        // With both rules a song says everything that keeps it.
        smartRules(SmartDownloadRules(enabled = true))
        world.waitUntil("the favorites to join") {
            cached.keys == setOf("so-al-1-1", "so-al-2-1", "so-al-3-1", "so-al-3-2") &&
                cached["so-al-1-1"]?.triggers == listOf("favorite", "playlist")
        }
    }

    @Test
    fun onAMeteredConnectionOnlyWhatTheUserAsksForIsDownloaded() {
        world.metered(true)
        signIn()
        smartRules(SmartDownloadRules(enabled = true))

        // The user's own download is the sign that the rules had their turn and passed.
        val harbor = song("al-2", "Harbor")
        world.graph.library.notifyChanged(LibraryChange.Favorites)
        val waited = System.nanoTime() + 3_000_000_000
        world.waitUntil("the rules to have had their turn") { System.nanoTime() > waited }
        offline.download(listOf(harbor))
        world.waitUntil("the download") { harbor.id in cached }

        assertEquals(setOf(harbor.id), cached.keys)
    }

    @Test
    fun aSongPlayedFromTheServerIsKeptUntilTheQuotaSaysOtherwise() {
        signIn()
        val harbor = song("al-2", "Harbor")

        world.graph.player.playSongs(listOf(harbor), index = 0)

        world.waitUntil("the played song to be kept") { cached[harbor.id]?.source == AudioCacheSource.Lru }
        assertEquals(1, offline.pools.value.lru.count)

        world.graph.settings.update { it.copy(cache = it.cache.copy(lruQuota = 1)) }
        world.waitUntil("the quota to be enforced") { cached.isEmpty() }
        assertNull(audioCache.file(harbor.id))
    }

    @Test
    fun aDownloadThatFailedRunsAgainWhenTheServerIsBack() {
        signIn()
        val harbor = song("al-2", "Harbor")
        world.server.failStreams = true

        offline.download(listOf(harbor))
        world.waitUntil("the download to fail") {
            world.server.requested("stream") && offline.downloads.value.isEmpty()
        }
        assertTrue(cached.isEmpty())

        // The server drops out of reach and comes back.
        world.server.failStreams = false
        world.graph.network.markServerUnreachable()
        world.graph.network.scheduleCheck(0)
        world.waitUntil("the download to be made up for") { cached[harbor.id]?.source == AudioCacheSource.Explicit }
    }

    @Test
    fun poolsAreClearedOneByOneOrAllAtOnce() {
        signIn()
        val album = world.await { world.graph.library.albumDetails("al-2") }!!
        offline.downloadAlbum(album)
        smartRules(SmartDownloadRules(enabled = true))
        world.waitUntil("downloads of both kinds") {
            offline.pools.value.explicit.count == 3 && offline.pools.value.smart.count == 2
        }

        world.await { offline.clearPool(AudioCacheSource.Explicit) }
        assertEquals(setOf("so-al-1-1", "so-al-3-2"), cached.keys)
        assertFalse(world.await { offline.items() }.any { it.type == CachedItemType.Album })

        world.await { world.graph.artwork.cover(listOf("al-al-1")) }
        world.await { offline.refreshCoverStats() }
        assertTrue(offline.pools.value.covers.count > 0)

        world.await { offline.clearAll() }
        assertTrue(cached.isEmpty())
        world.waitUntil("the pools to be empty") { offline.pools.value.isEmpty }
        assertTrue(world.await { offline.items() }.isEmpty())
    }

    @Test
    fun signingOutLeavesNothingOfTheAccountBehind() {
        signIn()
        val harbor = song("al-2", "Harbor")
        offline.download(listOf(harbor))
        world.waitUntil("the download") { harbor.id in cached }
        val file = audioCache.file(harbor.id)!!
        world.await { world.graph.services.preferences.addToPlayHistory("{\"id\":\"old-user-song\"}", 100) }
        world.graph.player.remember(listOf(harbor))
        val choices = java.io.File(world.graph.application.filesDir, "lyrics").apply { mkdirs() }
        java.io.File(choices, "old-selection.lrc").writeText("old account lyrics")
        world.graph.settings.update {
            it.copy(lyrics = it.lyrics.copy(selected = mapOf(
                "old-song" to github.realtvop.aonsoku.settings.SelectedCustomLyrics(disabled = true, offset = 3.0),
            )))
        }

        world.await { world.graph.signOut() }

        assertTrue(cached.isEmpty())
        assertFalse(file.exists())
        assertTrue(world.await { world.graph.services.preferences.getPlayHistory(100) }.isEmpty())
        assertTrue(world.graph.settings.current.lyrics.selected.isEmpty())
        assertFalse(choices.exists())
        assertEquals(0, world.await { library.getCoverCacheStats() }.count)
    }

    @Test
    fun theImagesOfTheLibraryAreFetchedAfterASyncWhenAskedFor() {
        world.graph.settings.update { it.copy(cache = it.cache.copy(syncCoverArt = true, coverArtConcurrency = 2)) }
        signIn()

        // Three artists by cover and by id, five albums, two playlists.
        world.waitUntil("the images") { offline.coverSync.value == null && offline.pools.value.covers.count == 13 }
        val fetched = coverRequests()
        assertEquals(13, fetched)
        assertNotNull(world.await { library.getCoverImageSize("ar-2") })
        assertNotNull(world.await { library.getCoverImageSize("pl-pl-1") })

        // What is there is not fetched again.
        offline.syncCoverArt()
        assertNotNull(offline.coverSync.value)
        world.waitUntil("the second pass to end") { offline.coverSync.value == null }
        assertEquals(fetched, coverRequests())

        // Song rows that show the album cover ask for it by the id of the album.
        world.graph.settings.update { it.copy(useAlbumCoverForSongs = true) }
        offline.syncCoverArt()
        world.waitUntil("the album ids") { offline.pools.value.covers.count == 18 }

        world.graph.settings.update { it.copy(cache = it.cache.copy(assetsQuota = 1)) }
        world.waitUntil("the quota to be enforced") { offline.pools.value.covers.count == 0 }
    }

    private fun signIn() {
        world.signIn()
        world.waitUntil("the library to sync") { world.graph.sync.state.value.phase == "done" }
    }

    private fun song(albumId: String, title: String): Song =
        world.await { world.graph.library.albumSongs(albumId) }.first { it.title == title }

    private fun smartRules(rules: SmartDownloadRules) =
        world.graph.settings.update { it.copy(cache = it.cache.copy(smartRules = rules)) }

    private fun coverRequests() = world.server.requests.count { it == "getCoverArt" }
}
