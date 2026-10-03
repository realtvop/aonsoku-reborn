package github.realtvop.aonsoku.plugins.audio

import org.json.JSONObject

/** Resolve the complete transferred queue without reshuffling its order. */
internal fun handoffPlaybackState(
    snapshot: JSONObject,
    songs: List<QueueSong>,
): PlaybackPersistState {
    require(snapshot.optString("mediaKind", "song") == "song")
    val songId = snapshot.getString("songId")
    val byId = songs.associateBy { it.id }
    fun ids(key: String): List<String> {
        val array = snapshot.optJSONArray(key) ?: return emptyList()
        return (0 until array.length()).map { array.getString(it) }
    }
    fun resolve(ids: List<String>) = ids.map { requireNotNull(byId[it]) { "Missing handoff song: $it" } }
    val inUserQueue = snapshot.optBoolean("inUserQueue", false)
    val contextIds = ids("contextQueue").let { if (it.isEmpty() && !inUserQueue) listOf(songId) else it }
    val context = resolve(contextIds)
    val user = resolve(ids("userQueue"))
    val index = snapshot.optInt("contextIndex", contextIds.indexOf(songId).coerceAtLeast(0))
    require((if (inUserQueue) user.firstOrNull() else context.getOrNull(index))?.id == songId) { "Invalid handoff current song" }
    val source = snapshot.optString("sourceId", "").split(":", limit = 2)
    val sourceId = if (source.size == 2 && source[0] in listOf("album", "playlist", "artist", "genre", "radio")) QueueSourceId(source[0], source[1]) else null
    val progress = snapshot.optDouble("progressSeconds", 0.0).takeIf { it.isFinite() }?.coerceAtLeast(0.0) ?: 0.0
    return PlaybackPersistState(
        contextSongs = context, currentIndex = index, userQueue = user,
        originalContextSongs = context, originalUserSongs = user,
        isShuffleActive = snapshot.optBoolean("shuffle", false),
        shuffleHistory = emptyList(), shuffleStartHistory = emptyList(),
        loopState = snapshot.optString("repeat", "off"), isInUserQueue = inUserQueue,
        playedUserQueueHistory = resolve(ids("restorePrevious")),
        sourceId = sourceId,
        sourceName = snapshot.optString("sourceName", "").takeUnless { it.isEmpty() || it == "null" },
        currentTime = progress,
    )
}
