package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioPluginRemoteCommandTest {
    @Test
    fun supportsAllCoordinationRemoteControlCommands() {
        val commands = listOf(
            "play",
            "pause",
            "toggle_play_pause",
            "previous",
            "next",
            "seek",
            "set_volume",
            "set_shuffle",
            "set_repeat",
            "toggle_like",
            "play_song",
            "play_album",
            "play_playlist",
            "add_to_queue_next",
            "add_to_queue_last",
            "remove_from_queue",
            "reorder_queue",
            "clear_queue",
            "play_at_index",
        )

        for (command in commands) {
            assertTrue(
                "$command should be handled natively",
                AudioPlugin.isSupportedRemoteControlCommand(command),
            )
        }
    }

    @Test
    fun rejectsUnknownRemoteControlCommands() {
        assertFalse(AudioPlugin.isSupportedRemoteControlCommand(""))
        assertFalse(AudioPlugin.isSupportedRemoteControlCommand("unsupported"))
    }
}
