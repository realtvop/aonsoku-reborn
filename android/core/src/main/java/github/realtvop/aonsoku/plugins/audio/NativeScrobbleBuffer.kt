package github.realtvop.aonsoku.plugins.audio

import java.util.Date

data class ScrobbleEntry(
    val songId: String,
    val playedDurationMs: Int,
    val timestamp: Double,
)

interface ScrobbleEntryStore {
    fun save(entries: List<ScrobbleEntry>)
    fun load(): List<ScrobbleEntry>
}

class NativeScrobbleBuffer(private val store: ScrobbleEntryStore) {
    private var entries: MutableList<ScrobbleEntry> = mutableListOf()
    private var currentSongId: String? = null
    private var currentSongDuration: Double? = null
    private var accumulatedMs: Int = 0
    private var segmentStartTime: Long? = null
    private var trackingStartTimestamp: Double = 0.0

    init {
        entries = store.load().toMutableList()
    }

    fun startTracking(songId: String, duration: Double = 0.0) {
        flushCurrent()
        currentSongId = songId
        currentSongDuration = duration
        accumulatedMs = 0
        segmentStartTime = System.currentTimeMillis()
        trackingStartTimestamp = Date().time * 1.0
    }

    fun pauseTracking() {
        if (segmentStartTime == null) return
        accumulatedMs += currentSegmentMs()
        segmentStartTime = null
    }

    fun resumeTracking() {
        if (currentSongId == null || segmentStartTime != null) return
        segmentStartTime = System.currentTimeMillis()
    }

    fun stopTracking(): ScrobbleEntry? {
        return flushCurrent()
    }

    fun getEntries(): List<ScrobbleEntry> = entries.toList()

    fun clear() {
        entries.clear()
        store.save(emptyList())
    }

    fun removeEntries(songIds: Set<String>) {
        entries.removeAll { it.songId in songIds }
        persistEntries()
    }

    var lastEntryDuration: Double? = null
        private set

    private fun currentSegmentMs(): Int {
        val start = segmentStartTime ?: return 0
        return (System.currentTimeMillis() - start).toInt()
    }

    private fun flushCurrent(): ScrobbleEntry? {
        val songId = currentSongId ?: return null

        val totalMs = accumulatedMs + currentSegmentMs()
        val timestamp = trackingStartTimestamp

        currentSongId = null
        segmentStartTime = null
        accumulatedMs = 0

        if (totalMs <= 0) {
            currentSongDuration = null
            return null
        }

        val entry = ScrobbleEntry(
            songId = songId,
            playedDurationMs = totalMs,
            timestamp = timestamp,
        )
        entries.add(entry)
        persistEntries()

        lastEntryDuration = currentSongDuration
        currentSongDuration = null
        return entry
    }

    private fun persistEntries() {
        store.save(entries.toList())
    }
}
