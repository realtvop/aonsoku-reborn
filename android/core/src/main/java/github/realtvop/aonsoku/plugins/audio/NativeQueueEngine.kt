package github.realtvop.aonsoku.plugins.audio

import org.json.JSONArray
import org.json.JSONObject

interface NativeQueueEngineDelegate {
    fun queueEngineLoadSong(engine: NativeQueueEngine, song: QueueSong, autoplay: Boolean, startTime: Double?)
    fun queueEngineDidAdvanceTo(engine: NativeQueueEngine, index: Int, songId: String, reason: QueueAdvanceReason)
    fun queueEngineDidChangeContents(engine: NativeQueueEngine, reason: String)
    fun queueEngineDidExhaustQueue(engine: NativeQueueEngine)
    fun queueEngineSeekToStart(engine: NativeQueueEngine, song: QueueSong)
}

class NativeQueueEngine {
    var delegate: NativeQueueEngineDelegate? = null

    var contextSongs: List<QueueSong> = emptyList()
        private set
    var originalContextSongs: List<QueueSong> = emptyList()
        private set
    var currentIndex: Int = 0
        private set

    var userQueue: List<QueueSong> = emptyList()
        private set
    var originalUserSongs: List<QueueSong> = emptyList()
        private set
    var isInUserQueue: Boolean = false
        private set
    var playedUserQueueHistory: List<QueueSong> = emptyList()
        private set

    var loopState: LoopState = LoopState.OFF
        private set
    var isShuffleActive: Boolean = false
        private set
    var shuffleHistory: List<String> = emptyList()
        private set
    var shuffleStartHistory: List<String> = emptyList()
        private set
    var sourceId: QueueSourceId? = null
        private set
    var sourceName: String? = null
        private set

    private val shuffleEngine = NativeShuffleEngine()
    private val prevSeekThreshold = 3.0

    private val maxShuffleHistory: Int
        get() = maxOf(20, minOf(contextSongs.size / 2, 200))

    private val maxShuffleStartHistory: Int
        get() = maxOf(10, minOf(contextSongs.size / 4, 50))

    val currentSong: QueueSong?
        get() {
            if (isInUserQueue && userQueue.isNotEmpty()) {
                return userQueue.first()
            }
            if (currentIndex >= 0 && currentIndex < contextSongs.size) {
                return contextSongs[currentIndex]
            }
            return null
        }

    val hasNext: Boolean
        get() {
            if (isInUserQueue && userQueue.size > 1) return true
            if (!isInUserQueue && userQueue.isNotEmpty()) return true
            if (currentIndex < contextSongs.size - 1) return true
            if (loopState == LoopState.ALL && contextSongs.isNotEmpty()) return true
            return false
        }

    val hasPrev: Boolean
        get() {
            if (playedUserQueueHistory.isNotEmpty()) return true
            if (isInUserQueue) return true
            if (currentIndex > 0) return true
            return false
        }

    // MARK: - Queue Setup

    fun setContextQueue(
        songs: List<QueueSong>,
        currentIndex: Int,
        autoplay: Boolean,
        startTime: Double?,
        sourceId: QueueSourceId? = null,
        sourceName: String? = null
    ) {
        this.contextSongs = songs
        this.originalContextSongs = emptyList()
        this.currentIndex = if (songs.isEmpty()) 0 else maxOf(0, minOf(currentIndex, songs.size - 1))
        this.userQueue = emptyList()
        this.originalUserSongs = emptyList()
        this.isInUserQueue = false
        this.playedUserQueueHistory = emptyList()
        this.isShuffleActive = false
        this.shuffleHistory = emptyList()
        this.sourceId = sourceId
        this.sourceName = sourceName

        currentSong?.let {
            delegate?.queueEngineLoadSong(this, it, autoplay, startTime)
        }
    }

    fun updateContextQueue(songs: List<QueueSong>, currentIndex: Int) {
        val previousSongId = currentSong?.id
        this.contextSongs = songs
        this.currentIndex = if (songs.isEmpty()) 0 else maxOf(0, minOf(currentIndex, songs.size - 1))
        this.originalContextSongs = originalContextSongs.filter { orig ->
            songs.any { it.id == orig.id }
        }

        val newSongId = currentSong?.id
        if (previousSongId != newSongId) {
            currentSong?.let {
                delegate?.queueEngineLoadSong(this, it, autoplay = true, startTime = null)
                delegate?.queueEngineDidAdvanceTo(this, this.currentIndex, it.id, QueueAdvanceReason.SKIP)
            }
        } else {
            delegate?.queueEngineDidChangeContents(this, "queue-edit")
        }
    }

    fun reorderContextQueue(fromIndex: Int, toIndex: Int) {
        if (fromIndex == toIndex) return
        if (fromIndex < 0 || fromIndex >= contextSongs.size) return
        if (toIndex < 0 || toIndex >= contextSongs.size) return

        val mutableSongs = contextSongs.toMutableList()
        val song = mutableSongs.removeAt(fromIndex)
        mutableSongs.add(toIndex, song)
        contextSongs = mutableSongs
        delegate?.queueEngineDidChangeContents(this, "queue-edit")
    }

    fun addToUserQueue(songs: List<QueueSong>, position: String) {
        val mutableUserQueue = userQueue.toMutableList()
        if (position == "next") {
            val insertIndex = if (isInUserQueue) 1 else 0
            mutableUserQueue.addAll(minOf(insertIndex, mutableUserQueue.size), songs)
        } else {
            mutableUserQueue.addAll(songs)
        }
        userQueue = mutableUserQueue
        delegate?.queueEngineDidChangeContents(this, "queue-edit")
    }

    fun removeFromUserQueue(indices: List<Int>) {
        val mutableUserQueue = userQueue.toMutableList()
        val sorted = indices.sortedDescending()
        for (idx in sorted) {
            if (idx >= 0 && idx < mutableUserQueue.size) {
                mutableUserQueue.removeAt(idx)
            }
        }
        userQueue = mutableUserQueue
        if (userQueue.isEmpty() && isInUserQueue) {
            isInUserQueue = false
        }
        delegate?.queueEngineDidChangeContents(this, "queue-edit")
    }

    fun clearUserQueue() {
        userQueue = emptyList()
        originalUserSongs = emptyList()
        playedUserQueueHistory = emptyList()
        if (isInUserQueue) {
            isInUserQueue = false
        }
        delegate?.queueEngineDidChangeContents(this, "queue-edit")
    }

    fun playAtIndex(index: Int, startTime: Double?) {
        if (index < 0 || index >= contextSongs.size) return
        isInUserQueue = false
        currentIndex = index
        currentSong?.let {
            delegate?.queueEngineLoadSong(this, it, autoplay = true, startTime = startTime)
            delegate?.queueEngineDidAdvanceTo(this, currentIndex, it.id, QueueAdvanceReason.SKIP)
        }
    }

    /**
     * Jump to a song in the user queue. Everything queued before it (including
     * the user-queue song that is playing, if any) moves to the played history
     * so "previous" can walk back through it.
     */
    fun playUserQueueAt(index: Int) {
        if (index < 0 || index >= userQueue.size) return
        if (isInUserQueue && index == 0) return

        if (!isInUserQueue) {
            currentSong?.let { pushShuffleHistory(it.id) }
        }
        val skipped = userQueue.take(index)
        skipped.forEach { pushShuffleHistory(it.id) }
        playedUserQueueHistory = playedUserQueueHistory + skipped
        userQueue = userQueue.drop(index)
        isInUserQueue = true
        notifyAdvance(QueueAdvanceReason.SKIP)
    }

    /**
     * Move a song inside the user queue. The song that is currently playing
     * from the user queue (index 0 while [isInUserQueue]) keeps its place.
     */
    fun reorderUserQueue(fromIndex: Int, toIndex: Int) {
        if (fromIndex == toIndex) return
        if (fromIndex < 0 || fromIndex >= userQueue.size) return
        if (toIndex < 0 || toIndex >= userQueue.size) return
        if (isInUserQueue && (fromIndex == 0 || toIndex == 0)) return

        val mutableUserQueue = userQueue.toMutableList()
        val song = mutableUserQueue.removeAt(fromIndex)
        mutableUserQueue.add(toIndex, song)
        userQueue = mutableUserQueue
        delegate?.queueEngineDidChangeContents(this, "queue-edit")
    }

    // MARK: - Playback Control

    fun handleEnded() {
        if (loopState == LoopState.ONE) {
            val userQueueRemaining = if (isInUserQueue) userQueue.size - 1 else userQueue.size
            if (userQueueRemaining > 0) {
                advanceToNext(QueueAdvanceReason.ENDED)
                return
            }
            currentSong?.let {
                delegate?.queueEngineSeekToStart(this, it)
            }
            return
        }
        advanceToNext(QueueAdvanceReason.ENDED)
    }

    fun skipToNext() {
        advanceToNext(QueueAdvanceReason.NEXT)
    }

    fun skipToPrevious(currentTime: Double) {
        if (currentTime > prevSeekThreshold) {
            currentSong?.let {
                delegate?.queueEngineSeekToStart(this, it)
            }
            return
        }
        advanceToPrevious()
    }

    // MARK: - Advance Logic

    private fun advanceToNext(reason: QueueAdvanceReason) {
        if (isInUserQueue) {
            val mutableUserQueue = userQueue.toMutableList()
            if (mutableUserQueue.isNotEmpty()) {
                val consumed = mutableUserQueue.removeAt(0)
                userQueue = mutableUserQueue
                playedUserQueueHistory = playedUserQueueHistory + consumed
                pushShuffleHistory(consumed.id)
            }

            if (userQueue.isNotEmpty()) {
                notifyAdvance(reason)
                return
            }

            isInUserQueue = false
            if (currentIndex < contextSongs.size - 1) {
                currentIndex++
            } else if (loopState == LoopState.ALL) {
                wrapToStart()
            }
            notifyAdvance(reason)
            return
        }

        if (userQueue.isNotEmpty()) {
            currentSong?.let {
                pushShuffleHistory(it.id)
            }
            isInUserQueue = true
            notifyAdvance(reason)
            return
        }

        currentSong?.let {
            pushShuffleHistory(it.id)
        }

        if (currentIndex < contextSongs.size - 1) {
            currentIndex++
            notifyAdvance(reason)
            return
        }

        if (loopState == LoopState.ALL) {
            wrapToStart()
            notifyAdvance(reason)
            return
        }

        delegate?.queueEngineDidExhaustQueue(this)
    }

    private fun advanceToPrevious() {
        if (playedUserQueueHistory.isNotEmpty()) {
            val mutableHistory = playedUserQueueHistory.toMutableList()
            val restored = mutableHistory.removeAt(mutableHistory.size - 1)
            playedUserQueueHistory = mutableHistory

            val mutableUserQueue = userQueue.toMutableList()
            mutableUserQueue.add(0, restored)
            userQueue = mutableUserQueue

            val wasInUserQueue = isInUserQueue
            isInUserQueue = true

            if (!wasInUserQueue && currentIndex > 0) {
                currentIndex--
            }

            notifyAdvance(QueueAdvanceReason.PREVIOUS)
            return
        }

        if (isInUserQueue) {
            isInUserQueue = false
            notifyAdvance(QueueAdvanceReason.PREVIOUS)
            return
        }

        if (currentIndex > 0) {
            currentIndex--
            notifyAdvance(QueueAdvanceReason.PREVIOUS)
        }
    }

    private fun wrapToStart() {
        val lastPlayedId = if (currentIndex in contextSongs.indices) contextSongs[currentIndex].id else null
        currentIndex = 0
        reshuffleForWrap(lastPlayedId)
    }

    private fun notifyAdvance(reason: QueueAdvanceReason) {
        val song = currentSong ?: return
        delegate?.queueEngineLoadSong(this, song, autoplay = true, startTime = null)
        delegate?.queueEngineDidAdvanceTo(this, currentIndex, song.id, reason)
    }

    // MARK: - Shuffle

    fun setShuffleActive(active: Boolean) {
        if (active) {
            applyShuffle()
        } else {
            applyUnshuffle()
        }
    }

    fun markAsShuffled(originalSongs: List<QueueSong>) {
        isShuffleActive = true
        originalContextSongs = originalSongs
    }

    fun setLoopState(state: LoopState) {
        this.loopState = state
    }

    private fun applyShuffle() {
        originalContextSongs = contextSongs

        currentSong?.let {
            shuffleStartHistory = shuffleEngine.pushToHistory(
                shuffleStartHistory, it.id, maxShuffleStartHistory
            )
        }

        val upcoming = contextSongs.drop(currentIndex + 1)
        if (upcoming.size > 1) {
            val shuffled = shuffleEngine.shuffleWithGapAvoidance(upcoming, shuffleHistory)
            contextSongs = contextSongs.take(currentIndex + 1) + shuffled
        }

        // The song playing from the user queue is its head and must stay there.
        val playingHead = if (isInUserQueue) userQueue.take(1) else emptyList()
        val pendingUserSongs = userQueue.drop(playingHead.size)
        if (pendingUserSongs.size > 1) {
            originalUserSongs = pendingUserSongs
            userQueue = playingHead +
                shuffleEngine.shuffleWithGapAvoidance(pendingUserSongs, shuffleHistory)
        }

        isShuffleActive = true
        delegate?.queueEngineDidChangeContents(this, "shuffle")
    }

    private fun applyUnshuffle() {
        val contextSongId = contextSongs.getOrNull(currentIndex)?.id
        if (originalContextSongs.isNotEmpty()) {
            val restoredIndex = originalContextSongs.indexOfFirst { it.id == contextSongId }
            contextSongs = originalContextSongs
            currentIndex = if (restoredIndex != -1) {
                restoredIndex
            } else {
                minOf(currentIndex, contextSongs.size - 1)
            }
        }

        restoreUserQueueOrder()

        originalContextSongs = emptyList()
        playedUserQueueHistory = emptyList()
        isShuffleActive = false
        shuffleHistory = emptyList()
        delegate?.queueEngineDidChangeContents(this, "unshuffle")
    }

    /**
     * Puts the pending user-queue songs back in the order they were queued in.
     * Only songs that are still pending are kept: songs played or removed while
     * shuffling stay gone, and songs queued in the meantime stay queued (ahead
     * of the restored ones when they were added to play next).
     */
    private fun restoreUserQueueOrder() {
        if (originalUserSongs.isEmpty()) return

        val playingHead = if (isInUserQueue) userQueue.take(1) else emptyList()
        val pending = userQueue.drop(playingHead.size).toMutableList()
        val originalIds = originalUserSongs.mapTo(HashSet()) { it.id }
        val addedToPlayNext = pending.takeWhile { it.id !in originalIds }
        repeat(addedToPlayNext.size) { pending.removeAt(0) }

        val restored = mutableListOf<QueueSong>()
        for (original in originalUserSongs) {
            val index = pending.indexOfFirst { it.id == original.id }
            if (index != -1) restored += pending.removeAt(index)
        }

        userQueue = playingHead + addedToPlayNext + restored + pending
        originalUserSongs = emptyList()
    }

    private fun reshuffleForWrap(lastPlayedSongId: String?) {
        if (!isShuffleActive || contextSongs.size <= 1) return

        val upcoming = contextSongs.drop(1)
        var reshuffled = shuffleEngine.shuffleWithGapAvoidance(upcoming, shuffleHistory).toMutableList()

        if (lastPlayedSongId != null) {
            val idx = reshuffled.indexOfFirst { it.id == lastPlayedSongId }
            if (idx != -1) {
                val song = reshuffled.removeAt(idx)
                reshuffled.add(song)
            }
        }

        contextSongs = listOf(contextSongs[0]) + reshuffled
    }

    private fun pushShuffleHistory(id: String) {
        shuffleHistory = shuffleEngine.pushToHistory(shuffleHistory, id, maxShuffleHistory)
    }

    // MARK: - State Restoration

    var isRestored: Boolean = false
        private set

    fun restoreState(persisted: PlaybackPersistState) {
        contextSongs = persisted.contextSongs
        currentIndex = persisted.currentIndex
        userQueue = persisted.userQueue
        originalContextSongs = persisted.originalContextSongs
        originalUserSongs = persisted.originalUserSongs
        isShuffleActive = persisted.isShuffleActive
        shuffleHistory = persisted.shuffleHistory
        shuffleStartHistory = persisted.shuffleStartHistory
        loopState = LoopState.fromValue(persisted.loopState)
        isInUserQueue = persisted.isInUserQueue
        playedUserQueueHistory = persisted.playedUserQueueHistory
        sourceId = persisted.sourceId
        sourceName = persisted.sourceName
        isRestored = true
    }

    fun clearRestoredFlag() {
        isRestored = false
    }

    // MARK: - State Export

    fun getFullState(currentTime: Double, duration: Double, isPlaying: Boolean): JSONObject {
        val state = JSONObject()

        val contextQueueObj = JSONObject()
        val songsArray = JSONArray()
        contextSongs.forEach { songsArray.put(it.toDict()) }
        contextQueueObj.put("songs", songsArray)
        contextQueueObj.put("currentIndex", currentIndex)
        contextQueueObj.put("sourceId", sourceId?.toDict() ?: JSONObject.NULL)
        contextQueueObj.put("sourceName", sourceName ?: JSONObject.NULL)
        state.put("contextQueue", contextQueueObj)

        val userQueueArray = JSONArray()
        userQueue.forEach { userQueueArray.put(it.toDict()) }
        state.put("userQueue", userQueueArray)

        val originalContextSongsArray = JSONArray()
        originalContextSongs.forEach { originalContextSongsArray.put(it.toDict()) }
        state.put("originalContextSongs", originalContextSongsArray)

        val originalUserSongsArray = JSONArray()
        originalUserSongs.forEach { originalUserSongsArray.put(it.toDict()) }
        state.put("originalUserSongs", originalUserSongsArray)

        state.put("isInUserQueue", isInUserQueue)
        state.put("isShuffleActive", isShuffleActive)

        val shuffleHistoryArray = JSONArray()
        shuffleHistory.forEach { shuffleHistoryArray.put(it) }
        state.put("shuffleHistory", shuffleHistoryArray)

        val shuffleStartHistoryArray = JSONArray()
        shuffleStartHistory.forEach { shuffleStartHistoryArray.put(it) }
        state.put("shuffleStartHistory", shuffleStartHistoryArray)

        val playedUserQueueHistoryArray = JSONArray()
        playedUserQueueHistory.forEach { playedUserQueueHistoryArray.put(it.toDict()) }
        state.put("playedUserQueueHistory", playedUserQueueHistoryArray)

        state.put("loopState", loopState.value)
        state.put("isPlaying", isPlaying)
        state.put("currentTime", currentTime)
        state.put("duration", duration)
        state.put("currentSongId", currentSong?.id ?: JSONObject.NULL)
        state.put("isRestored", isRestored)

        return state
    }
}
