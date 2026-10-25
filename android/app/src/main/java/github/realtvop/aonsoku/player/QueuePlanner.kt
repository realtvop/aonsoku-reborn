package github.realtvop.aonsoku.player

import github.realtvop.aonsoku.plugins.audio.NativeShuffleEngine
import github.realtvop.aonsoku.plugins.audio.QueueSong

/**
 * Pure queue arithmetic shared by the player controller. It reproduces the
 * queue model of the web player: the context queue always starts at the song
 * that is playing, followed by what comes next.
 */
object QueuePlanner {
    private val shuffler = NativeShuffleEngine()

    /**
     * Playback order for starting [songs] at [index]. With repeat-all the
     * earlier songs are rotated to the end; otherwise they are dropped. With
     * [shuffle] the upcoming songs are shuffled and the start song stays first.
     */
    fun build(
        songs: List<QueueSong>,
        index: Int,
        repeatAll: Boolean,
        shuffle: Boolean,
    ): List<QueueSong> {
        if (songs.isEmpty()) return emptyList()
        val start = index.coerceIn(0, songs.lastIndex)
        val ordered = if (repeatAll) songs.drop(start) + songs.take(start) else songs.drop(start)
        if (!shuffle || ordered.size <= 1) return ordered
        return listOf(ordered.first()) +
            shuffler.shuffleWithGapAvoidance(ordered.drop(1), emptyList())
    }

    /** Random start for a shuffled list that avoids recently used starts. */
    fun pickStartIndex(songs: List<QueueSong>, startHistory: List<String>): Int =
        shuffler.pickRandomStartIndex(songs.size, startHistory) { songs[it].id }

    fun pushStartHistory(history: List<String>, id: String, queueSize: Int): List<String> =
        shuffler.pushToHistory(history, id, maxOf(10, minOf(queueSize / 4, 50)))

    /**
     * Starting something new asks first when it would discard songs the user
     * queued manually. The song playing from the user queue does not count.
     */
    fun shouldConfirmReplacement(
        isPlaying: Boolean,
        userQueueSize: Int,
        isInUserQueue: Boolean,
    ): Boolean {
        val remaining = userQueueSize - if (isInUserQueue) 1 else 0
        return isPlaying && remaining > 0
    }

    /** Songs to enqueue when the user picks "play after this song" instead. */
    fun replacementPlayNext(songs: List<QueueSong>, index: Int, shuffle: Boolean): List<QueueSong> {
        if (songs.isEmpty()) return emptyList()
        if (shuffle) return shuffler.shuffleWithGapAvoidance(songs, emptyList())
        return songs.drop(index.coerceIn(0, songs.lastIndex))
    }

    /**
     * Result of removing the context song at [removedIndex]: the new list and
     * the index of the current song in it, or null when the last song would
     * be removed.
     */
    fun removeFromContext(
        songs: List<QueueSong>,
        currentIndex: Int,
        isInUserQueue: Boolean,
        removedIndex: Int,
    ): Pair<List<QueueSong>, Int>? {
        if (removedIndex !in songs.indices) return null
        val remaining = songs.toMutableList().apply { removeAt(removedIndex) }
        if (remaining.isEmpty()) return null
        val nextIndex = when {
            isInUserQueue -> currentIndex - if (removedIndex <= currentIndex) 1 else 0
            removedIndex < currentIndex -> currentIndex - 1
            removedIndex == currentIndex -> minOf(currentIndex, remaining.lastIndex)
            else -> currentIndex
        }
        return remaining to nextIndex.coerceAtLeast(0)
    }
}
