package github.realtvop.aonsoku.plugins.data.image

import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.data.db.dao.CacheMetaDao
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class ImageCacheManager(private val cacheDir: File, private val cacheMetaDao: CacheMetaDao) {
    private val generation = AtomicLong()
    private val publication = Mutex()
    private val client = OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).build()

    suspend fun downloadCoverImage(coverArtId: String, size: String, credentials: ServerCredentials): File {
        val revision = generation.get()
        val p = SubsonicAuthBuilder.buildQueryParams(credentials.username, credentials.password, credentials.authType, credentials.protocolVersion).toMutableMap().apply { put("id", coverArtId); put("size", size) }
        val url = "${credentials.serverUrl.trimEnd('/')}/rest/getCoverArt?${p.entries.joinToString("&") { (k, v) -> "${java.net.URLEncoder.encode(k, "UTF-8")}=${java.net.URLEncoder.encode(v, "UTF-8")}" }}"
        val resp = client.newCall(Request.Builder().url(url).get().build()).execute()
        if (!resp.isSuccessful) throw ImageCacheError.DownloadFailed(Exception("HTTP ${resp.code}"))
        val ct = resp.header("Content-Type", "image/jpeg") ?: "image/jpeg"
        val data = resp.body?.bytes() ?: throw ImageCacheError.DownloadFailed(Exception("Empty body"))
        return publish(coverArtId, data, ct, size, revision)
    }

    suspend fun downloadAvatar(username: String, size: String, credentials: ServerCredentials): File {
        val revision = generation.get()
        val p = SubsonicAuthBuilder.buildQueryParams(credentials.username, credentials.password, credentials.authType, credentials.protocolVersion).toMutableMap().apply { put("username", username); put("size", size) }
        val url = "${credentials.serverUrl.trimEnd('/')}/rest/getAvatar?${p.entries.joinToString("&") { (k, v) -> "${java.net.URLEncoder.encode(k, "UTF-8")}=${java.net.URLEncoder.encode(v, "UTF-8")}" }}"
        val resp = client.newCall(Request.Builder().url(url).get().build()).execute()
        if (!resp.isSuccessful) throw ImageCacheError.DownloadFailed(Exception("HTTP ${resp.code}"))
        val ct = resp.header("Content-Type", "image/jpeg") ?: "image/jpeg"
        val data = resp.body?.bytes() ?: throw ImageCacheError.DownloadFailed(Exception("Empty body"))
        return publish(username, data, ct, size, revision)
    }

    suspend fun storeCoverImage(coverArtId: String, data: ByteArray, contentType: String, coverSize: String): File =
        publish(coverArtId, data, contentType, coverSize, generation.get())

    private suspend fun publish(id: String, data: ByteArray, contentType: String, size: String, revision: Long): File =
        publication.withLock {
            if (revision != generation.get()) throw CancellationException("Artwork account changed")
            val dir = ImageCacheUtils.cacheDirectory(cacheDir, true)
            val cid = ImageCacheUtils.cacheId(id)
            val file = File(dir, "$cid.${ImageCacheUtils.fileExtension(contentType)}")
            ImageCacheUtils.deleteCoverImageFiles(dir, cid)
            file.writeBytes(data)
            val now = System.currentTimeMillis()
            cacheMetaDao.upsert(CacheMetaEntity("cover:$id", id, "cover", "explicit", coverSize = size, sizeBytes = data.size.toLong(), cachedAt = now, lastAccessedAt = now))
            file
        }

    suspend fun resolveCoverImage(coverArtId: String): File? {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, false); if (!dir.exists()) return null
        val cid = ImageCacheUtils.cacheId(coverArtId); val f = ImageCacheUtils.coverImageFile(dir, cid) ?: return null
        if (!f.exists()) return null
        try { cacheMetaDao.getByKey("cover:$coverArtId")?.let { cacheMetaDao.upsert(it.copy(lastAccessedAt = System.currentTimeMillis())) } } catch (_: Exception) {}
        return f
    }

    suspend fun deleteCoverImage(coverArtId: String): Boolean {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, false); if (!dir.exists()) return false; val cid = ImageCacheUtils.cacheId(coverArtId)
        val d = ImageCacheUtils.deleteCoverImageFiles(dir, cid)
        try { cacheMetaDao.delete("cover:$coverArtId") } catch (_: Exception) {}; return d
    }

    suspend fun clearCoverImages(): Int {
        generation.incrementAndGet()
        return publication.withLock {
            val dir = ImageCacheUtils.cacheDirectory(cacheDir, false)
            val files = dir.listFiles().orEmpty()
            files.forEach { check(it.delete() || !it.exists()) { "Could not remove artwork" } }
            cacheMetaDao.deleteByType("cover")
            files.size
        }
    }

    suspend fun getCoverImageSize(coverArtId: String): Pair<Long, String?>? {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, false); val cid = ImageCacheUtils.cacheId(coverArtId)
        val f = ImageCacheUtils.coverImageFile(dir, cid) ?: return null; if (!f.exists()) return null
        val r = try { cacheMetaDao.getByKey("cover:$coverArtId") } catch (_: Exception) { null }
        return Pair(f.length(), r?.coverSize)
    }
}
