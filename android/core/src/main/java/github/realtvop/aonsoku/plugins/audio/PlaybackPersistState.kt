package github.realtvop.aonsoku.plugins.audio

import org.json.JSONArray
import org.json.JSONObject

data class PlaybackPersistState(
    var contextSongs: List<QueueSong>,
    var currentIndex: Int,
    var userQueue: List<QueueSong>,
    var originalContextSongs: List<QueueSong>,
    var originalUserSongs: List<QueueSong>,
    var isShuffleActive: Boolean,
    var shuffleHistory: List<String>,
    var shuffleStartHistory: List<String>,
    var loopState: String,
    var isInUserQueue: Boolean,
    var playedUserQueueHistory: List<QueueSong>,
    var sourceId: QueueSourceId?,
    var sourceName: String?,
    var currentTime: Double
) {
    companion object {
        fun from(engine: NativeQueueEngine, currentTime: Double): PlaybackPersistState {
            return PlaybackPersistState(
                contextSongs = engine.contextSongs,
                currentIndex = engine.currentIndex,
                userQueue = engine.userQueue,
                originalContextSongs = engine.originalContextSongs,
                originalUserSongs = engine.originalUserSongs,
                isShuffleActive = engine.isShuffleActive,
                shuffleHistory = engine.shuffleHistory,
                shuffleStartHistory = engine.shuffleStartHistory,
                loopState = engine.loopState.value,
                isInUserQueue = engine.isInUserQueue,
                playedUserQueueHistory = engine.playedUserQueueHistory,
                sourceId = engine.sourceId,
                sourceName = engine.sourceName,
                currentTime = currentTime
            )
        }

        fun fromJson(json: JSONObject): PlaybackPersistState {
            val contextSongsArray = json.optJSONArray("contextSongs")
            val contextSongs = mutableListOf<QueueSong>()
            if (contextSongsArray != null) {
                for (i in 0 until contextSongsArray.length()) {
                    contextSongs.add(QueueSong.from(contextSongsArray.getJSONObject(i)))
                }
            }

            val userQueueArray = json.optJSONArray("userQueue")
            val userQueue = mutableListOf<QueueSong>()
            if (userQueueArray != null) {
                for (i in 0 until userQueueArray.length()) {
                    userQueue.add(QueueSong.from(userQueueArray.getJSONObject(i)))
                }
            }

            val originalContextSongsArray = json.optJSONArray("originalContextSongs")
            val originalContextSongs = mutableListOf<QueueSong>()
            if (originalContextSongsArray != null) {
                for (i in 0 until originalContextSongsArray.length()) {
                    originalContextSongs.add(QueueSong.from(originalContextSongsArray.getJSONObject(i)))
                }
            }

            val originalUserSongsArray = json.optJSONArray("originalUserSongs")
            val originalUserSongs = mutableListOf<QueueSong>()
            if (originalUserSongsArray != null) {
                for (i in 0 until originalUserSongsArray.length()) {
                    originalUserSongs.add(QueueSong.from(originalUserSongsArray.getJSONObject(i)))
                }
            }

            val playedUserQueueHistoryArray = json.optJSONArray("playedUserQueueHistory")
            val playedUserQueueHistory = mutableListOf<QueueSong>()
            if (playedUserQueueHistoryArray != null) {
                for (i in 0 until playedUserQueueHistoryArray.length()) {
                    playedUserQueueHistory.add(QueueSong.from(playedUserQueueHistoryArray.getJSONObject(i)))
                }
            }

            val shuffleHistoryArray = json.optJSONArray("shuffleHistory")
            val shuffleHistory = mutableListOf<String>()
            if (shuffleHistoryArray != null) {
                for (i in 0 until shuffleHistoryArray.length()) {
                    shuffleHistory.add(shuffleHistoryArray.getString(i))
                }
            }

            val shuffleStartHistoryArray = json.optJSONArray("shuffleStartHistory")
            val shuffleStartHistory = mutableListOf<String>()
            if (shuffleStartHistoryArray != null) {
                for (i in 0 until shuffleStartHistoryArray.length()) {
                    shuffleStartHistory.add(shuffleStartHistoryArray.getString(i))
                }
            }

            val sourceIdObj = if (json.has("sourceId") && !json.isNull("sourceId")) json.getJSONObject("sourceId") else null
            val sourceId = QueueSourceId.from(sourceIdObj)
            val sourceName = if (json.has("sourceName") && !json.isNull("sourceName")) json.getString("sourceName") else null

            return PlaybackPersistState(
                contextSongs = contextSongs,
                currentIndex = json.optInt("currentIndex", 0),
                userQueue = userQueue,
                originalContextSongs = originalContextSongs,
                originalUserSongs = originalUserSongs,
                isShuffleActive = json.optBoolean("isShuffleActive", false),
                shuffleHistory = shuffleHistory,
                shuffleStartHistory = shuffleStartHistory,
                loopState = json.optString("loopState", "off"),
                isInUserQueue = json.optBoolean("isInUserQueue", false),
                playedUserQueueHistory = playedUserQueueHistory,
                sourceId = sourceId,
                sourceName = sourceName,
                currentTime = json.optDouble("currentTime", 0.0)
            )
        }
    }

    fun toJson(): JSONObject {
        val json = JSONObject()
        val contextArray = JSONArray()
        contextSongs.forEach { contextArray.put(it.toDict()) }
        json.put("contextSongs", contextArray)

        json.put("currentIndex", currentIndex)

        val userArray = JSONArray()
        userQueue.forEach { userArray.put(it.toDict()) }
        json.put("userQueue", userArray)

        val origContextArray = JSONArray()
        originalContextSongs.forEach { origContextArray.put(it.toDict()) }
        json.put("originalContextSongs", origContextArray)

        val origUserArray = JSONArray()
        originalUserSongs.forEach { origUserArray.put(it.toDict()) }
        json.put("originalUserSongs", origUserArray)

        json.put("isShuffleActive", isShuffleActive)

        val shuffleHistArray = JSONArray()
        shuffleHistory.forEach { shuffleHistArray.put(it) }
        json.put("shuffleHistory", shuffleHistArray)

        val shuffleStartHistArray = JSONArray()
        shuffleStartHistory.forEach { shuffleStartHistArray.put(it) }
        json.put("shuffleStartHistory", shuffleStartHistArray)

        json.put("loopState", loopState)
        json.put("isInUserQueue", isInUserQueue)

        val playedUserArray = JSONArray()
        playedUserQueueHistory.forEach { playedUserArray.put(it.toDict()) }
        json.put("playedUserQueueHistory", playedUserArray)

        sourceId?.let { json.put("sourceId", it.toDict()) }
        sourceName?.let { json.put("sourceName", it) }
        json.put("currentTime", currentTime)

        return json
    }
}
