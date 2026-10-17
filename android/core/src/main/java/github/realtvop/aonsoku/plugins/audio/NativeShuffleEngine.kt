package github.realtvop.aonsoku.plugins.audio

import kotlin.random.Random

class NativeShuffleEngine {
    fun shuffleWithGapAvoidance(songs: List<QueueSong>, history: List<String>): List<QueueSong> {
        if (history.isEmpty()) {
            val result = songs.toMutableList()
            fisherYatesInPlace(result)
            return result
        }

        val historyIndex = history.mapIndexed { idx, id -> id to idx }.toMap()

        val fresh = mutableListOf<QueueSong>()
        val recent = mutableListOf<QueueSong>()

        for (song in songs) {
            if (historyIndex.containsKey(song.id)) {
                recent.add(song)
            } else {
                fresh.add(song)
            }
        }

        fisherYatesInPlace(fresh)
        recent.sortBy { historyIndex[it.id] ?: 0 }

        return fresh + recent
    }

    fun pickRandomStartIndex(
        count: Int,
        startHistory: List<String>,
        getId: (Int) -> String
    ): Int {
        if (count <= 0) return 0

        val historySet = startHistory.toSet()
        val maxAttempts = minOf(count, startHistory.size + 10)

        for (i in 0 until maxAttempts) {
            val idx = Random.nextInt(count)
            if (!historySet.contains(getId(idx))) return idx
        }

        for (i in 0 until count) {
            if (!historySet.contains(getId(i))) return i
        }

        return Random.nextInt(count)
    }

    fun pushToHistory(history: List<String>, id: String, maxLen: Int): List<String> {
        val result = history.filter { it != id }.toMutableList()
        result.add(id)
        if (result.size > maxLen) {
            return result.subList(result.size - maxLen, result.size)
        }
        return result
    }

    private fun <T> fisherYatesInPlace(list: MutableList<T>) {
        if (list.size <= 1) return
        for (i in list.size - 1 downTo 1) {
            val j = Random.nextInt(i + 1)
            val temp = list[i]
            list[i] = list[j]
            list[j] = temp
        }
    }
}
