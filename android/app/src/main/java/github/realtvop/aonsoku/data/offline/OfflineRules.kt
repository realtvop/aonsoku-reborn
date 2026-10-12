package github.realtvop.aonsoku.data.offline

import github.realtvop.aonsoku.plugins.audio.AudioCacheSource
import github.realtvop.aonsoku.plugins.audio.CachedAudio

/**
 * Which songs the smart-download rules want kept, and why. A song matched by
 * several rules carries all of them and stays until the last one lets go.
 */
object SmartDownloads {
    const val FAVORITE = "favorite"
    const val PLAYLIST = "playlist"

    /**
     * [favoriteSongs] and [playlistSongs] are the songs the two rules match;
     * a rule that is switched off passes none. While [playlistsKnown] is
     * false (a favorite playlist could not be read), the songs [cached] for
     * the playlist rule are kept as they are instead of being let go.
     */
    fun wanted(
        favoriteSongs: Collection<String>,
        playlistSongs: Collection<String>,
        playlistsKnown: Boolean = true,
        cached: Collection<CachedAudio> = emptyList(),
    ): Map<String, List<String>> {
        val triggers = LinkedHashMap<String, MutableList<String>>()
        fun add(songId: String, trigger: String) {
            if (songId.isEmpty()) return
            val list = triggers.getOrPut(songId) { ArrayList(2) }
            if (trigger !in list) list += trigger
        }
        favoriteSongs.forEach { add(it, FAVORITE) }
        playlistSongs.forEach { add(it, PLAYLIST) }
        if (!playlistsKnown) {
            cached.filter { it.source == AudioCacheSource.Smart && PLAYLIST in it.triggers }
                .forEach { add(it.songId, PLAYLIST) }
        }
        return triggers
    }
}

/**
 * The cached songs to mark as gone from the server: those that are not among
 * [existing], the cached songs the synced library still lists. Null when no
 * verdict should be passed: when most of the cached songs would be newly
 * marked at once, the library is more likely incomplete than the songs gone.
 */
fun missingFromLibrary(
    cached: Collection<CachedAudio>,
    existing: Set<String>,
    maxNewShare: Double = 0.5,
): Set<String>? {
    val missing = cached.filter { it.songId !in existing }
    val newlyMissing = missing.count { !it.removedFromServer }
    if (newlyMissing > cached.size * maxNewShare) return null
    return missing.mapTo(LinkedHashSet()) { it.songId }
}
