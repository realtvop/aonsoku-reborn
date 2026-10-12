package github.realtvop.aonsoku.data.image

import github.realtvop.aonsoku.data.NetworkMonitor
import github.realtvop.aonsoku.plugins.data.LibraryService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
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
) {
    private val downloads = Semaphore(MAX_PARALLEL_DOWNLOADS)
    private val inFlight = ConcurrentHashMap<String, CompletableDeferred<File?>>()

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
        runCatching { library.resolveCoverImage(id)?.file }.getOrNull()?.takeIf { it.exists() }

    suspend fun avatar(username: String): File? {
        if (username.isEmpty()) return null
        cached(username)?.let { return it }
        if (!network.online) return null
        return download("avatar:$username") { library.downloadAvatar(username, AVATAR_SIZE).file }
    }

    private suspend fun download(key: String, block: suspend () -> File): File? {
        val pending = CompletableDeferred<File?>()
        val existing = inFlight.putIfAbsent(key, pending)
        if (existing != null) return existing.await()
        try {
            val file = downloads.withPermit {
                try {
                    block()
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    null
                }
            }
            pending.complete(file)
            return file
        } catch (error: CancellationException) {
            pending.complete(null)
            throw error
        } finally {
            inFlight.remove(key, pending)
        }
    }

    companion object {
        const val CACHE_SIZE = "700"
        private const val AVATAR_SIZE = "128"
        private const val MAX_PARALLEL_DOWNLOADS = 6
    }
}
