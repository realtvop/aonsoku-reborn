package github.realtvop.aonsoku.smoke

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
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
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.player.RepeatMode
import github.realtvop.aonsoku.session.SessionState
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

    @Test
    fun signingInThroughTheLoginScreenOpensHome() {
        compose.setContent { AonsokuApp(world.graph) }

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
    }

    @Test
    fun albumListOpensAnAlbumWithItsTracks() {
        openLibrary()
        compose.onNodeWithText("Albums").performClick()
        waitForText("Paper Boats")
        waitForText("Hearthside")

        // A two-disc album: tracks are grouped under disc headers.
        compose.onNodeWithText("Northern Lights").performClick()
        waitForText("First Snow")
        waitForText("About Northern Lights")
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

        compose.onNodeWithText("Get info").performClick()
        waitForText("900 kbps")
        waitForText("FLAC")
    }

    @Test
    fun artistListOpensAnArtistPage() {
        openLibrary()
        compose.onNodeWithText("Artists").performClick()
        waitForText("Aurora Lane")
        waitForText("Cedar and Stone")

        compose.onNodeWithText("Blue Meridian").performClick()
        waitForText("About Blue Meridian")
        scrollTo("Popular")
        scrollTo("Low Tide")
        scrollTo("Recent albums")
        scrollTo("Related artists")
    }

    @Test
    fun playlistsOpenIncludingRepeatedSongsAndEmptyOnes() {
        openLibrary()
        waitForText("Morning Mix")

        compose.onNodeWithText("Morning Mix").performClick()
        // "First Snow" is in the playlist twice.
        waitUntil("the playlist songs") {
            compose.onAllNodesWithText("First Snow").fetchSemanticsNodes().size == 2
        }
        waitForText("Songs for the first coffee")

        back()
        waitForText("Empty Crate")
        compose.onNodeWithText("Empty Crate").performClick()
        waitForText("This playlist does not have any songs!")
    }

    @Test
    fun favoritesSongsAndRadiosList() {
        // The radios entry is hidden unless it is switched on in the settings.
        world.graph.settings.update { it.copy(hideRadios = false) }
        openLibrary()
        compose.onNodeWithText("Favorites").performClick()
        waitForText("First Snow")
        waitForText("Undertow")

        back()
        waitForText("Playlists")
        compose.onNodeWithText("Songs").performClick()
        waitForText("First Snow")
        scrollTo("Kindling")

        back()
        waitForText("Playlists")
        compose.onNodeWithText("Radios").performClick()
        waitForText("Harbor FM")
    }

    @Test
    fun searchFindsAlbumsSongsAndArtists() {
        openHome()
        compose.onNodeWithContentDescription("Search").performClick()
        waitForText("Search for an album, artist or song")

        compose.onNode(hasSetTextAction()).performTextInput("tid")
        waitForText("Tidal Hours")
        waitForText("Low Tide")

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
        compose.onNodeWithText("Remove from queue").performClick()
        waitUntil("the song to leave the queue") {
            contextTitles() == listOf("Low Tide", "Slack Water")
        }

        compose.onNodeWithText("Slack Water").performClick()
        waitUntil("the tapped song to play") { playerState().current?.title == "Slack Water" }
        waitForText("No songs in queue")

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
        compose.onNodeWithText("Sleep timer").performClick()
        waitForText("End of current track")
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

    /** Signs in and waits for the synced home page. */
    private fun openHome() {
        world.signIn()
        compose.setContent { AonsokuApp(world.graph) }
        waitForText("Recently added")
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

    private fun playerState() = world.graph.player.state.value

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
}
