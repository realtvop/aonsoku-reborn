package github.realtvop.aonsoku.data.offline

import github.realtvop.aonsoku.plugins.audio.AudioCacheSource

/** What a pool of the cache holds. */
data class PoolStats(val count: Int = 0, val sizeBytes: Long = 0)

/** The pools the storage settings show, each with its own rules for removal. */
data class CachePools(
    val explicit: PoolStats = PoolStats(),
    val smart: PoolStats = PoolStats(),
    val lru: PoolStats = PoolStats(),
    val covers: PoolStats = PoolStats(),
) {
    val isEmpty: Boolean
        get() = explicit.count + smart.count + lru.count + covers.count == 0

    fun audio(source: AudioCacheSource): PoolStats = when (source) {
        AudioCacheSource.Explicit -> explicit
        AudioCacheSource.Smart -> smart
        AudioCacheSource.Lru -> lru
    }
}

/** How far the download of the library's images is. */
data class CoverSyncProgress(val processed: Int, val total: Int) {
    val percent: Int get() = if (total > 0) processed * 100 / total else 0
}

enum class CachedItemType(val id: String) {
    Audio("audio"),
    Cover("cover"),
    Album("album"),
    Playlist("playlist"),
    ;

    companion object {
        fun of(id: String): CachedItemType? = entries.firstOrNull { it.id == id }
    }
}

/** One entry of the cache index, named for the cache manager. */
data class CachedItem(
    val key: String,
    val id: String,
    val type: CachedItemType,
    /** Why it is kept; images have no source of their own. */
    val source: AudioCacheSource?,
    val name: String,
    val subtitle: String?,
    val sizeBytes: Long,
    val cachedAt: Long,
    val removedFromServer: Boolean,
)
