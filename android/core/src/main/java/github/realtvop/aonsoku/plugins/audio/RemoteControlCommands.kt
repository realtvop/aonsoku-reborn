package github.realtvop.aonsoku.plugins.audio

/** Coordination command types the native playback service executes itself. */
object RemoteControlCommands {
    private val supported = setOf(
        "play",
        "pause",
        "toggle_play_pause",
        "previous",
        "next",
        "seek",
        "set_shuffle",
        "set_repeat",
        "set_volume",
        "play_song",
        "play_album",
        "play_playlist",
        "play_at_index",
        "add_to_queue_next",
        "add_to_queue_last",
        "remove_from_queue",
        "reorder_queue",
        "clear_queue",
        "toggle_like",
    )

    fun isSupported(type: String): Boolean = type in supported
}
