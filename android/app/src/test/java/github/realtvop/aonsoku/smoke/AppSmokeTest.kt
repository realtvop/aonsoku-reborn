package github.realtvop.aonsoku.smoke

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.player.RepeatMode
import github.realtvop.aonsoku.session.SessionState
import github.realtvop.aonsoku.settings.LyricsSource
import github.realtvop.aonsoku.settings.ThemeMode
import github.realtvop.aonsoku.ui.AonsokuApp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Runs the real app (graph, native services, Room, HTTP client, Compose UI)
 * on the JVM against [FakeSubsonicServer] and walks through its screens. The
 * point is that every page composes, loads, and navigates without crashing.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
// The graph is built per test by SmokeWorld instead of by AonsokuApplication.
@Config(application = Application::class, qualifiers = "w411dp-h891dp-xxhdpi")
class AppSmokeTest {
    @get:Rule(order = 0)
    val world = SmokeWorld()

    @get:Rule(order = 1)
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val screenshots = SmokeScreenshots(compose)

    @Test
    fun signingInThroughTheLoginScreenOpensHome() {
        showApp()
        snapshot("login")

        // The field starts out with a scheme.
        compose.onNodeWithText("URL").performTextReplacement(world.server.url)
        compose.onNodeWithText("Username").performTextInput(SmokeWorld.USERNAME)
        compose.onNodeWithText("Password").performTextInput(SmokeWorld.PASSWORD)
        compose.onNodeWithText("Connect").performClick()

        waitUntil("the session to start") {
            world.graph.session.state.value is SessionState.SignedIn
        }
        waitForText("Recently added")
        assertTrue(world.server.requested("ping"))
    }

    @Test
    fun homeShowsTheSyncedLibrary() {
        openHome()
        waitForText("Northern Lights")
        compose.onNodeWithText("Recently added").assertIsDisplayed()
        waitUntil("the covers to load") { world.server.requested("getCoverArt") }
        snapshot("home")
    }

    @Test
    fun albumListOpensAnAlbumWithItsTracks() {
        openLibrary()
        compose.onNodeWithText("Albums").performClick()
        waitForText("Paper Boats")
        waitForText("Hearthside")
        snapshot("albums")

        // A two-disc album: tracks are grouped under disc headers.
        compose.onNodeWithText("Northern Lights").performClick()
        waitForText("First Snow")
        waitForText("About Northern Lights")
        snapshot("album")
        scrollTo("Disc 2")
        scrollTo("Thaw")
        scrollTo("More from this artist")
        scrollTo("Paper Boats")

        back()
        waitForText("Paper Boats")
    }

    @Test
    fun songMenuOpensFromAnAlbumPage() {
        openLibrary()
        compose.onNodeWithText("Albums").performClick()
        waitForText("Tidal Hours")
        compose.onNodeWithText("Tidal Hours").performClick()
        waitForText("Undertow")

        compose.onNodeWithContentDescription("More options for Undertow").performClick()
        waitForText("Play next")
        waitForText("Add to playlist")
        waitForText("Go to artist")
        snapshot("song-menu")

        compose.onNodeWithText("Get info").performClick()
        waitForText("900 kbps")
        waitForText("FLAC")
        snapshot("song-info")
    }

    @Test
    fun artistListOpensAnArtistPage() {
        openLibrary()
        compose.onNodeWithText("Artists").performClick()
        waitForText("Aurora Lane")
        waitForText("Cedar and Stone")
        snapshot("artists")

        compose.onNodeWithText("Blue Meridian").performClick()
        waitForText("About Blue Meridian")
        snapshot("artist")
        scrollTo("Popular")
        scrollTo("Low Tide")
        scrollTo("Recent albums")
        scrollTo("Related artists")
    }

    @Test
    fun playlistsOpenIncludingRepeatedSongsAndEmptyOnes() {
        openLibrary()
        waitForText("Morning Mix")
        snapshot("library")

        compose.onNodeWithText("Morning Mix").performClick()
        // "First Snow" is in the playlist twice.
        waitUntil("the playlist songs") {
            compose.onAllNodesWithText("First Snow").fetchSemanticsNodes().size == 2
        }
        waitForText("Songs for the first coffee")
        snapshot("playlist")

        back()
        waitForText("Empty Crate")
        compose.onNodeWithText("Empty Crate").performClick()
        waitForText("This playlist does not have any songs!")
        snapshot("playlist-empty")
    }

    @Test
    fun favoritesSongsAndRadiosList() {
        // The radios entry is hidden unless it is switched on in the settings.
        world.graph.settings.update { it.copy(hideRadios = false) }
        openLibrary()
        compose.onNodeWithText("Favorites").performClick()
        waitForText("First Snow")
        waitForText("Undertow")
        snapshot("favorites")

        back()
        waitForText("Playlists")
        compose.onNodeWithText("Songs").performClick()
        waitForText("First Snow")
        snapshot("songs")
        scrollTo("Kindling")

        back()
        waitForText("Playlists")
        compose.onNodeWithText("Radios").performClick()
        waitForText("Harbor FM")
        snapshot("radios")
    }

    @Test
    fun searchFindsAlbumsSongsAndArtists() {
        openHome()
        compose.onNodeWithContentDescription("Search").performClick()
        waitForText("Search for an album, artist or song")
        snapshot("search")

        compose.onNode(hasSetTextAction()).performTextInput("tid")
        waitForText("Tidal Hours")
        waitForText("Low Tide")
        snapshot("search-results")

        compose.onNode(hasSetTextAction()).performTextReplacement("cedar")
        waitForText("Cedar and Stone")
    }

    @Test
    fun tappingASongLoadsItIntoThePlayer() {
        openLibrary()
        compose.onNodeWithText("Albums").performClick()
        waitForText("Tidal Hours")
        compose.onNodeWithText("Tidal Hours").performClick()
        waitForText("Undertow")

        compose.onNodeWithText("Undertow").performClick()
        waitUntil("the song to become current") {
            world.graph.player.state.value.current?.title == "Undertow"
        }
        // The mini player shows the song next to its row on the page.
        waitUntil("the mini player") {
            compose.onAllNodesWithText("Undertow").fetchSemanticsNodes().size >= 2
        }
        // The album continues after the tapped song.
        val state = world.graph.player.state.value
        assertEquals(listOf("Undertow", "Slack Water"), state.contextSongs.map { it.title })

        waitUntil("the stream request") { world.server.requested("stream") }
        snapshot("mini-player")

        compose.onNodeWithContentDescription("Next").performClick()
        waitUntil("the next song") {
            world.graph.player.state.value.current?.title == "Slack Water"
        }
        waitUntil("the mini player to follow") {
            compose.onAllNodesWithText("Slack Water").fetchSemanticsNodes().size >= 2
        }
    }

    @Test
    fun miniPlayerExpandsIntoTheFullscreenPlayer() {
        play(album = "Tidal Hours", song = "Low Tide")
        expandPlayer("Low Tide")

        // The page and the mini player are covered: only the player shows the song.
        assertEquals(1, compose.onAllNodesWithText("Low Tide").fetchSemanticsNodes().size)
        snapshot("player")
        compose.onNodeWithText("Tidal Hours").assertIsDisplayed()

        compose.onNodeWithContentDescription("Like Low Tide by Blue Meridian").performClick()
        waitUntil("the like to reach the server") { world.server.requested("star") }
        waitForDescription("Remove like from Low Tide by Blue Meridian")

        compose.onNodeWithContentDescription("Enable repeat").performClick()
        waitUntil("repeat all") { playerState().repeat == RepeatMode.All }
        waitForDescription("Enable repeat one")

        compose.onNodeWithContentDescription("Next").performClick()
        waitUntil("the next song") { playerState().current?.title == "Undertow" }
        waitForText("Undertow")

        back()
        waitForPlayerToClose()
        // The page below is in reach again, with the mini player on top of it.
        waitUntil("the mini player to return") {
            compose.onAllNodesWithText("Undertow").fetchSemanticsNodes().size >= 2
        }

        expandPlayer("Undertow")
        compose.onNodeWithContentDescription("Settings").performClick()
        waitForText("Color intensity")
        snapshot("player-colors")
    }

    @Test
    fun queueTabReordersRemovesAndPlaysUpcomingSongs() {
        play(album = "Tidal Hours", song = "Low Tide")
        expandPlayer("Low Tide")

        compose.onNodeWithContentDescription("Queue").performClick()
        waitForText("CONTINUE PLAYING")
        waitForText("From Tidal Hours")
        waitForText("Undertow")
        waitForText("Slack Water")
        snapshot("queue")

        // The handle at the end of a row drags it; one row down swaps the two.
        compose.onNodeWithText("Undertow").performTouchInput {
            down(Offset(width - 24.dp.toPx(), centerY))
            repeat(8) { moveBy(Offset(0f, 10.dp.toPx())) }
            up()
        }
        waitUntil("the dragged song to move down") {
            contextTitles() == listOf("Low Tide", "Slack Water", "Undertow")
        }

        compose.onNodeWithText("Undertow").performTouchInput { longClick() }
        waitForText("Remove from queue")
        snapshot("queue-menu")
        compose.onNodeWithText("Remove from queue").performClick()
        waitUntil("the song to leave the queue") {
            contextTitles() == listOf("Low Tide", "Slack Water")
        }

        compose.onNodeWithText("Slack Water").performClick()
        waitUntil("the tapped song to play") { playerState().current?.title == "Slack Water" }
        waitForText("No songs in queue")
        snapshot("queue-history")

        // Back leaves the queue for the playing view first, then closes the player.
        back()
        waitForDescription("Volume")
        back()
        waitForPlayerToClose()
    }

    @Test
    fun currentSongMenuStartsASleepTimerAndFollowsLinks() {
        play(album = "Tidal Hours", song = "Low Tide")
        expandPlayer("Low Tide")

        compose.onNodeWithContentDescription("More options for Low Tide").performClick()
        waitForText("Sleep timer")
        snapshot("current-song-menu")
        compose.onNodeWithText("Sleep timer").performClick()
        waitForText("End of current track")
        snapshot("sleep-timer")
        compose.onNodeWithText("15 min").performClick()
        waitUntil("the sleep timer to start") { world.graph.player.sleepTimer.value.active }

        compose.onNodeWithContentDescription("More options for Low Tide").performClick()
        waitUntil("the time left on the timer") {
            compose.onAllNodes(hasText("remaining", substring = true))
                .fetchSemanticsNodes().isNotEmpty()
        }

        // A link leads to a page, so the player gets out of the way.
        compose.onNodeWithText("Go to artist").performClick()
        waitForText("About Blue Meridian")
        waitForPlayerToClose()
    }

    @Test
    fun lyricsFollowTheSongAndSeekOnTap() {
        play(album = "Tidal Hours", song = "Low Tide")
        expandPlayer("Low Tide")

        compose.onNodeWithContentDescription("Lyrics").performClick()
        waitForText("The tide goes out")
        // The second track of the server's lyrics is the translation.
        waitForText("La marea baja")
        snapshot("lyrics")

        compose.onNodeWithText("Carry what I cannot keep").performClick()
        waitUntil("the tapped line to be sung") { world.graph.player.progress.value.position >= 2.5 }
        waitUntil("the tapped line to be lit") {
            compose.onAllNodes(hasText("Carry what I cannot keep") and isSelected())
                .fetchSemanticsNodes().isNotEmpty()
        }

        // The song on top leads back to the playing view, which names the album.
        compose.onNodeWithText("Low Tide").performClick()
        waitForText("Tidal Hours")
    }

    @Test
    fun lyricsOfASongCanBeShiftedAndTurnedOff() {
        play(album = "Tidal Hours", song = "Low Tide")
        expandPlayer("Low Tide")

        compose.onNodeWithContentDescription("Lyrics settings").performClick()
        waitForText("Low Tide by Blue Meridian")
        // Without a custom lyrics server there are no entries to choose from.
        waitForText("Use a custom lyrics service to choose more lyrics")
        snapshot("lyrics-settings")

        compose.onNodeWithContentDescription("Lyrics offset")
            .performSemanticsAction(SemanticsActions.SetProgress) { it(1.5f) }
        waitForText("+1.5s")
        assertEquals(listOf(1.5), lyricChoices().map { it.offset })
        compose.onNodeWithText("Reset").performClick()
        waitUntil("the offset to be forgotten") { lyricChoices().isEmpty() }

        compose.onNodeWithText("Turn off lyrics").performClick()
        waitForText("Lyrics off")
        waitUntil("the lyrics tab to close") { !isEnabled("Lyrics") }
        compose.onNodeWithText("Lyrics off").performClick()
        waitForText("Turn off lyrics")
        waitUntil("the lyrics tab to open") { isEnabled("Lyrics") }
    }

    @Test
    fun customLyricsServerOffersEntriesToChooseFrom() {
        world.graph.settings.update {
            it.copy(
                lyrics = it.lyrics.copy(
                    customServerEnabled = true,
                    customServerUrl = world.server.customLyricsUrl,
                    customServerPassword = "open sesame",
                    sourcePriority = listOf(LyricsSource.Custom, LyricsSource.Navidrome, LyricsSource.LrcLib),
                ),
            )
        }
        play(album = "Tidal Hours", song = "Undertow")
        expandPlayer("Undertow")

        // Until an entry is chosen the first one is used.
        compose.onNodeWithContentDescription("Lyrics").performClick()
        waitForText("First entry of Undertow")
        assertEquals("open sesame", world.server.customLyricsAuthorization)

        compose.onNodeWithContentDescription("Lyrics settings").performClick()
        waitForText("ID: entry-1")
        snapshot("lyrics-entries")
        scrollTo("Undertow (Live)")
        waitForText("Romaji")
        compose.onAllNodesWithText("Select").onLast().performClick()

        // Choosing an entry leads back to the lyrics, which are the chosen ones now.
        waitForText("Second entry of Undertow")
        waitForText("Sekando entori")
        assertEquals(listOf("entry-2"), lyricChoices().map { it.key })
    }

    @Test
    fun lyricsMissingOnTheServerComeFromLrcLib() {
        play(album = "Tidal Hours", song = "Slack Water")
        expandPlayer("Slack Water")

        compose.onNodeWithContentDescription("Lyrics").performClick()
        waitForText("Still water")
        waitForText("Nothing pulls, nothing pushes")
        assertTrue(world.server.requested("lrclib"))
        snapshot("lyrics-plain")
    }

    @Test
    fun aSongWithoutLyricsClosesTheLyricsTab() {
        play(album = "Paper Boats", song = "Harbor")
        expandPlayer("Harbor")

        waitUntil("the search for lyrics to end") { !isEnabled("Lyrics") }
        assertTrue(world.server.requested("getLyricsBySongId"))
        assertTrue(world.server.requested("lrclib"))
    }

    /** Signs in and waits for the synced home page. */
    private fun openHome() {
        world.signIn()
        showApp()
        waitForText("Recently added")
    }

    private fun showApp() {
        if (screenshots.dark) world.graph.settings.update { it.copy(themeMode = ThemeMode.Dark) }
        compose.setContent { AonsokuApp(world.graph) }
    }

    private fun openLibrary() {
        openHome()
        compose.onNodeWithText("Library").performClick()
        waitForText("Playlists")
    }

    /** Starts [song] from the page of [album] and waits for the mini player to show it. */
    private fun play(album: String, song: String) {
        openLibrary()
        compose.onNodeWithText("Albums").performClick()
        waitForText(album)
        compose.onNodeWithText(album).performClick()
        waitForText(song)
        compose.onNodeWithText(song).performClick()
        waitUntil("the song to become current") { playerState().current?.title == song }
        waitUntil("the mini player") {
            compose.onAllNodesWithText(song).fetchSemanticsNodes().size >= 2
        }
    }

    /** Taps the mini player, which comes after the page that also lists [song]. */
    private fun expandPlayer(song: String) {
        compose.onAllNodesWithText(song).onLast().performClick()
        waitForDescription("Close")
    }

    private fun waitForPlayerToClose() = waitUntil("the player to close") {
        compose.onAllNodesWithContentDescription("Close").fetchSemanticsNodes().isEmpty()
    }

    /** Saves what is on screen when the run asks for screenshots. */
    private fun snapshot(name: String) {
        if (!screenshots.enabled) return
        // Artwork and transitions get a moment to settle.
        val settled = System.nanoTime() + SNAPSHOT_SETTLE_MS * 1_000_000
        waitUntil("the screen to settle") { System.nanoTime() > settled }
        screenshots.save(name)
    }

    private fun playerState() = world.graph.player.state.value

    private fun lyricChoices() = world.graph.settings.current.lyrics.selected.values.toList()

    private fun isEnabled(description: String): Boolean =
        compose.onAllNodes(hasContentDescription(description) and isEnabled())
            .fetchSemanticsNodes().isNotEmpty()

    private fun contextTitles() = playerState().contextSongs.map { it.title }

    /** Scrolls the page until [text] is composed; lazy pages only hold what is visible. */
    private fun scrollTo(text: String) = waitUntil("\"$text\" in the page") {
        runCatching {
            compose.onAllNodes(hasScrollToNodeAction()).onFirst().performScrollToNode(hasText(text))
        }.isSuccess
    }

    private fun back() {
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.waitForIdle()
    }

    private fun waitForText(text: String) = waitUntil("\"$text\" on screen") {
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
    }

    private fun waitForDescription(description: String) = waitUntil("[$description] on screen") {
        compose.onAllNodesWithContentDescription(description).fetchSemanticsNodes().isNotEmpty()
    }

    /** Waits while both the app's main thread and the composition keep running. */
    private fun waitUntil(what: String, condition: () -> Boolean) = try {
        world.waitUntil(what) {
            compose.waitForIdle()
            condition()
        }
    } catch (error: AssertionError) {
        throw AssertionError("${error.message}\n  on screen: ${visibleTexts()}\n  ${world.describe()}", error)
    }

    private fun visibleTexts(): String = compose.onAllNodes(isRoot()).fetchSemanticsNodes()
        .flatMap { root -> root.texts() }
        .joinToString(" | ")
        .take(900)

    private fun SemanticsNode.texts(): List<String> {
        val own = config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } +
            config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().map { "[$it]" }
        return own + children.flatMap { it.texts() }
    }

    private companion object {
        const val SNAPSHOT_SETTLE_MS = 1_200L
    }
}
