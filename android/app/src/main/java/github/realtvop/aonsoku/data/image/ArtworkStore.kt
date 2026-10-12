package github.realtvop.aonsoku.data.image

import github.realtvop.aonsoku.data.NetworkMonitor
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.plugins.data.LibraryService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Resolves artwork to files in the native image cache owned by
 * `LibraryService`. A cover is downloaded once at [CACHE_SIZE] pixels and that
 * copy serves every display size, online and offline.
 */
class ArtworkStore(
    private val library: LibraryService,
    private val network: NetworkMonitor,
    /** Owns the downloads, so one that several images wait for outlives any of them. */
    private val scope: CoroutineScope,
) {
    private val downloads = Semaphore(MAX_PARALLEL_DOWNLOADS)
    private val inFlight = ConcurrentHashMap<String, Deferred<File?>>()

    /**
     * Returns the first cached file among [ids]; when none is cached the
     * first id is downloaded (if the server is reachable).
     */
    suspend fun cover(ids: List<String>): File? {
        val candidates = ids.filter { it.isNotEmpty() }.distinct()
        for (id in candidates) {
            cached(id)?.let { return it }
        }
        val primary = candidates.firstOrNull() ?: return null
        if (!network.online) return null
        return download("cover:$primary") { library.downloadCoverImage(primary, CACHE_SIZE).file }
    }

    /** Cached file for [id] without touching the network. */
    suspend fun cached(id: String): File? =
        runSuspendCatching { library.resolveCoverImage(id)?.file }.getOrNull()?.takeIf { it.exists() }

    suspend fun avatar(username: String): File? {
        if (username.isEmpty()) return null
        cached(username)?.let { return it }
        if (!network.online) return null
        return download("avatar:$username") { library.downloadAvatar(username, AVATAR_SIZE).file }
    }

    /**
     * Downloads once per [key]: every image asking for the same artwork waits
     * for the same download. A caller that goes away (an image scrolled off
     * screen) only stops waiting; the download finishes for the others and for
     * the cache.
     */
    private suspend fun download(key: String, block: suspend () -> File): File? {
        val created = scope.async(start = CoroutineStart.LAZY) {
            downloads.withPermit { runSuspendCatching { block() }.getOrNull() }
        }
        val existing = inFlight.putIfAbsent(key, created)
        if (existing != null) {
            created.cancel()
            return existing.await()
        }
        created.invokeOnCompletion { inFlight.remove(key, created) }
        created.start()
        return created.await()
    }

    companion object {
        const val CACHE_SIZE = "700"
        private const val AVATAR_SIZE = "128"
        private const val MAX_PARALLEL_DOWNLOADS = 8
    }
}
