package github.realtvop.aonsoku.smoke

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
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
