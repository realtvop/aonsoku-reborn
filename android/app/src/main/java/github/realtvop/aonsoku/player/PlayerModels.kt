package github.realtvop.aonsoku.player

import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.plugins.audio.QueueSourceId

enum class RepeatMode(val value: String) {
    Off("off"),
    All("all"),
    One("one"),
    ;

    /** Off → All → One → Off, the order of the repeat button. */
    fun next(): RepeatMode = when (this) {
        Off -> All
        All -> One
        One -> Off
    }

    companion object {
        fun fromValue(value: String): RepeatMode = entries.firstOrNull { it.value == value } ?: Off
    }
}

enum class MediaType { Song, Radio }

data class PlaybackProgress(
    val position: Double = 0.0,
    val duration: Double = 0.0,
    val buffered: Double = 0.0,
)

/** What the queue was started from, such as an album or a playlist. */
data class QueueSource(val type: String, val id: String) {
    fun toSourceId(): QueueSourceId = QueueSourceId(type, id)

    companion object {
        fun album(id: String) = QueueSource("album", id)

        fun playlist(id: String) = QueueSource("playlist", id)
    }
}

data class PlayerState(
    /** The playback service is bound and its state has been read. */
    val connected: Boolean = false,
    val mediaType: MediaType = MediaType.Song,
    val current: QueueSong? = null,
    val radio: Radio? = null,
    val isPlaying: Boolean = false,
    /** Buffering or switching to another song. */
    val isLoading: Boolean = false,
    val shuffle: Boolean = false,
    val repeat: RepeatMode = RepeatMode.Off,
    val contextSongs: List<QueueSong> = emptyList(),
    val contextIndex: Int = 0,
    val userQueue: List<QueueSong> = emptyList(),
    val isInUserQueue: Boolean = false,
    val playedUserQueueHistory: List<QueueSong> = emptyList(),
    val source: QueueSourceId? = null,
    val sourceName: String? = null,
    val isCurrentStarred: Boolean = false,
) {
    val hasMedia: Boolean get() = current != null || radio != null

    val isRadio: Boolean get() = mediaType == MediaType.Radio

    /** User-queued songs that have not started yet. */
    val upcomingUserQueue: List<QueueSong>
        get() = if (isInUserQueue) userQueue.drop(1) else userQueue

    /** Context songs after the one that is (or was last) playing. */
    val upcomingContext: List<QueueSong>
        get() = contextSongs.drop(contextIndex + 1)

    val hasNext: Boolean
        get() {
            if (isRadio) return false
            val remainingContext = contextSongs.size - contextIndex - 1
            return upcomingUserQueue.isNotEmpty() ||
                remainingContext > 0 ||
                (repeat == RepeatMode.All && contextSongs.isNotEmpty())
        }

    val hasPrevious: Boolean
        get() = !isRadio &&
            (playedUserQueueHistory.isNotEmpty() || isInUserQueue || contextIndex > 0)

    val isPlayingOneSong: Boolean get() = contextSongs.size + userQueue.size <= 1
}

data class SleepTimerState(
    val active: Boolean = false,
    val endOfTrack: Boolean = false,
    /** Wall-clock time at which a duration timer fires. */
    val endsAtMillis: Long = 0,
) {
    fun remainingSeconds(now: Long = System.currentTimeMillis()): Int =
        ((endsAtMillis - now) / 1000).toInt().coerceAtLeast(0)
}

/** A play request waiting for the user to decide what happens to queued songs. */
data class ReplacementRequest(
    val songs: List<QueueSong>,
    val index: Int,
    val shuffle: Boolean,
    val source: QueueSource?,
    val sourceName: String?,
)
