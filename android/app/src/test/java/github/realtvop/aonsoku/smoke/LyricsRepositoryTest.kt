package github.realtvop.aonsoku.smoke

import android.app.Application
import github.realtvop.aonsoku.data.lyrics.LyricsCandidate
import github.realtvop.aonsoku.data.lyrics.LyricsRepository
import github.realtvop.aonsoku.data.lyrics.LyricsSong
import github.realtvop.aonsoku.settings.LyricsSource
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
 * The lyric lookups and per-song choices on the real services, against the
 * fake server standing in for the music server, LRCLIB, and a custom lyrics
 * server.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class LyricsRepositoryTest {
    @get:Rule
    val world = SmokeWorld()

    private val lyrics get() = world.graph.lyrics

    private val lowTide = LyricsSong("so-al-3-1", "Blue Meridian", "Low Tide", "Tidal Hours", 180.0)
    private val undertow = LyricsSong("so-al-3-2", "Blue Meridian", "Undertow", "Tidal Hours", 187.0)
    private val slackWater = LyricsSong("so-al-3-3", "Blue Meridian", "Slack Water", "Tidal Hours", 194.0)
    private val harbor = LyricsSong("so-al-2-1", "Aurora Lane", "Harbor", "Paper Boats", 180.0)

    @Before
    fun signIn() {
        world.signIn()
        world.waitUntil("the server to be in reach") { world.graph.network.online }
    }

    private fun requests(endpoint: String) = world.server.requests.count { it == endpoint }

    private fun useCustomServer(first: Boolean = true) = world.graph.settings.update {
        it.copy(
            lyrics = it.lyrics.copy(
                customServerEnabled = true,
                customServerUrl = world.server.customLyricsUrl,
                sourcePriority = if (first) {
                    listOf(LyricsSource.Custom, LyricsSource.Navidrome, LyricsSource.LrcLib)
                } else {
                    listOf(LyricsSource.Navidrome, LyricsSource.LrcLib, LyricsSource.Custom)
                },
            ),
        )
    }

    private fun choices() = world.graph.settings.current.lyrics.selected

    @Test
    fun structuredLyricsAreKeptInTheLibrary() {
        val first = world.await { lyrics.load(lowTide) }
        assertEquals(listOf("eng", "spa"), first.structured.map { it.lang })
        assertTrue(first.structured.first().synced)
        assertNotNull(world.await { world.graph.services.library.getLyrics(lowTide.id) })

        val again = world.await { lyrics.load(lowTide) }
        assertEquals(first.structured, again.structured)
        assertEquals(1, requests("getLyricsBySongId"))
    }

    @Test
    fun textComesFromTheFirstSourceThatHasItAndIsCached() {
        val fromServer = world.await { lyrics.load(undertow) }
        assertTrue(fromServer.text?.value.orEmpty().startsWith("[00:00.20]Pulled under"))
        assertEquals(0, requests("lrclib"))

        val fromLrcLib = world.await { lyrics.load(slackWater) }
        assertTrue(fromLrcLib.text?.value.orEmpty().startsWith("Still water"))

        world.await { lyrics.load(undertow) }
        world.await { lyrics.load(slackWater) }
        assertEquals(2, requests("getLyrics"))
        assertEquals(1, requests("lrclib"))
    }

    @Test
    fun aSongWithoutLyricsIsNotLookedUpAgainRightAway() {
        val nothing = world.await { lyrics.load(harbor) }
        assertTrue(nothing.structured.isEmpty())
        assertNull(nothing.text)

        world.await { lyrics.load(harbor) }
        assertEquals(1, requests("getLyricsBySongId"))
        assertEquals(1, requests("getLyrics"))
        assertEquals(1, requests("lrclib"))
    }

    @Test
    fun lrcLibIsLeftAloneWhenTurnedOff() {
        world.graph.settings.update { it.copy(lrcLibEnabled = false) }
        assertNull(world.await { lyrics.load(slackWater) }.text)
        assertEquals(0, requests("lrclib"))
    }

    @Test
    fun aCustomServerIsOnlyAskedInItsTurn() {
        useCustomServer(first = false)
        world.await { lyrics.load(undertow) }
        assertEquals(0, requests("custom-lyrics"))

        useCustomServer(first = true)
        val custom = world.await { lyrics.load(undertow) }
        assertEquals("[00:00.20]First entry of Undertow\n[00:02.00]Its second line", custom.text?.value)
        assertEquals(1, requests("getLyrics"))
    }

    @Test
    fun aChosenEntryIsKeptOnTheDeviceAndUsedFromThere() {
        useCustomServer()
        val candidates = world.await { lyrics.candidates("Undertow", "Blue Meridian") }
        assertEquals(listOf("entry-1", "entry-2"), candidates.map { it.id })

        world.await { lyrics.choose(undertow, candidates[1], index = 1) }
        val choice = choices().getValue(undertow.key)
        assertEquals("entry-2", choice.key)
        assertEquals("Undertow (Live)", choice.title)
        assertTrue(choice.hasRomaji)

        val asked = requests("custom-lyrics")
        val chosen = world.await { lyrics.load(undertow) }
        assertEquals("[00:00.20]Second entry of Undertow\n[00:02.00]Sung live", chosen.text?.value)
        assertEquals("[00:00.20]Sekando entori", chosen.text?.romaji)
        assertEquals(asked, requests("custom-lyrics"))
    }

    @Test
    fun choosingAnEntryKeepsTheOffsetOfTheSong() {
        useCustomServer()
        world.await { lyrics.setOffset(undertow, 0.5) }
        world.await {
            lyrics.choose(undertow, LyricsCandidate(id = "x", lyrics = "[00:01.00]chosen"), index = 0)
        }
        val choice = choices().getValue(undertow.key)
        assertEquals("x", choice.key)
        assertEquals(0.5, choice.offset, 0.0)
        // An entry without names is called like the song.
        assertEquals("Undertow", choice.title)
        assertEquals("Blue Meridian", choice.artist)

        // Without an offset the entry stays chosen.
        world.await { lyrics.setOffset(undertow, 0.0) }
        assertEquals("x", choices().getValue(undertow.key).key)
    }

    @Test
    fun offsetsAreRoundedLimitedAndForgottenAtZero() {
        world.await { lyrics.setOffset(lowTide, 0.34) }
        assertEquals(0.3, choices().getValue(lowTide.key).offset, 1e-9)
        world.await { lyrics.setOffset(lowTide, -7.0) }
        assertEquals(LyricsRepository.OFFSET_MIN, choices().getValue(lowTide.key).offset, 0.0)
        world.await { lyrics.setOffset(lowTide, 0.0) }
        assertTrue(choices().isEmpty())
    }

    @Test
    fun lyricsTurnedOffAreNotLookedUp() {
        world.await { lyrics.setDisabled(lowTide, true) }
        assertTrue(choices().getValue(lowTide.key).disabled)
        val nothing = world.await { lyrics.load(lowTide) }
        assertTrue(nothing.structured.isEmpty())
        assertEquals(0, requests("getLyricsBySongId"))

        world.await { lyrics.setDisabled(lowTide, false) }
        assertTrue(choices().isEmpty())
        assertFalse(world.await { lyrics.load(lowTide) }.structured.isEmpty())
    }

    @Test
    fun onlyTheNewestChoicesAreKept() {
        useCustomServer()
        world.await { lyrics.choose(undertow, LyricsCandidate(id = "old", lyrics = "old lyrics"), index = 0) }
        world.await {
            repeat(LyricsRepository.MAX_CHOICES) { number ->
                lyrics.setOffset(LyricsSong("so-$number", "Artist", "Song $number"), 0.1)
            }
        }
        assertEquals(LyricsRepository.MAX_CHOICES, choices().size)
        assertFalse(undertow.key in choices())

        // The lyrics of the choice that had to go went with it: the server is asked again.
        val text = world.await { lyrics.load(undertow) }.text
        assertEquals("[00:00.20]First entry of Undertow\n[00:02.00]Its second line", text?.value)
    }

    @Test
    fun changingAChoiceAnnouncesThatLyricsMayDiffer() {
        val before = lyrics.revision.value
        world.await { lyrics.setDisabled(lowTide, true) }
        assertEquals(before + 1, lyrics.revision.value)
    }
}
