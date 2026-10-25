package github.realtvop.aonsoku.smoke

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The sleep timer on the real playback service, against the fake server. */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class SleepTimerTest {
    @get:Rule
    val world = SmokeWorld()

    private val player get() = world.graph.player

    @Test
    fun theEndOfTrackTimerStopsAtTheStartOfTheSongAndPlayPlaysItAgain() {
        world.signIn()
        world.waitUntil("the library to sync") { world.graph.sync.state.value.phase == "done" }
        world.waitUntil("the player to connect") { player.state.value.connected }
        val songs = world.await { world.graph.library.albumSongs("al-2") }
        // The song ends as soon as it has arrived.
        world.server.throttleStreams = false

        player.startEndOfTrackTimer()
        player.playSongs(songs, index = 0)

        world.waitUntil("the timer to fire") {
            player.state.value.current?.id == songs[0].id && !player.sleepTimer.value.active
        }
        world.waitUntil("the song to be back at its start") {
            !player.state.value.isPlaying && player.progress.value.position == 0.0
        }
        assertEquals(songs[0].id, player.state.value.current?.id)
        assertFalse(player.sleepTimer.value.active)

        // A player left at the end of a song would ignore this.
        player.play()

        world.waitUntil("the next song") { player.state.value.current?.id == songs[1].id }
    }
}
