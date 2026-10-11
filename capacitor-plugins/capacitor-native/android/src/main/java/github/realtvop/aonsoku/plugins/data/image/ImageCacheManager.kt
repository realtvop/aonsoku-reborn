package github.realtvop.aonsoku.plugins.data.image

import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.data.db.dao.CacheMetaDao
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class ImageCacheManager(private val cacheDir: File, private val cacheMetaDao: CacheMetaDao) {
    private val client = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val networkSlots = Semaphore(6)

    suspend fun downloadCoverImage(coverArtId: String, size: String, credentials: ServerCredentials): File = download(coverArtId, "getCoverArt", "id", size, credentials)
    suspend fun downloadAvatar(username: String, size: String, credentials: ServerCredentials): File = download(username, "getAvatar", "username", size, credentials)

    private suspend fun download(id: String, endpoint: String, parameter: String, size: String, credentials: ServerCredentials): File = locks.getOrPut(id) { Mutex() }.withLock {
        val cached = resolveCoverImage(id)
        val cachedSize = cacheMetaDao.getByKey("cover:$id")?.coverSize?.toIntOrNull() ?: 0
        if (cached != null && cachedSize >= (size.toIntOrNull() ?: 0)) return@withLock cached
        val parameters = SubsonicAuthBuilder.buildQueryParams(credentials.username, credentials.password, credentials.authType, credentials.protocolVersion).toMutableMap().apply { put(parameter, id); put("size", size) }
        val query = parameters.entries.joinToString("&") { (key, value) -> "${java.net.URLEncoder.encode(key, "UTF-8")}=${java.net.URLEncoder.encode(value, "UTF-8")}" }
        networkSlots.withPermit {
            client.newCall(Request.Builder().url("${credentials.serverUrl.trimEnd('/')}/rest/$endpoint?$query").build()).execute().use { response ->
                if (!response.isSuccessful) throw ImageCacheError.DownloadFailed(Exception("HTTP ${response.code}"))
                val contentType = response.header("Content-Type", "image/jpeg") ?: "image/jpeg"
                if (!contentType.startsWith("image/")) throw ImageCacheError.DownloadFailed(Exception("Invalid image response"))
                val bytes = response.body?.bytes()?.takeIf { it.isNotEmpty() } ?: throw ImageCacheError.DownloadFailed(Exception("Empty image"))
                storeCoverImage(id, bytes, contentType, size)
            }
        }
    }

    suspend fun storeCoverImage(coverArtId: String, data: ByteArray, contentType: String, coverSize: String): File {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, true)
        val id = ImageCacheUtils.cacheId(coverArtId)
        val file = File(dir, "$id.${ImageCacheUtils.fileExtension(contentType)}")
        val temporary = File.createTempFile("image-", ".tmp", dir)
        try {
            temporary.writeBytes(data)
            check(temporary.renameTo(file)) { "Cannot save image" }
            ImageCacheUtils.cachedImageExtensions.filter { !file.name.endsWith(".$it") }.forEach { File(dir, "$id.$it").delete() }
        } finally { temporary.delete() }
        val now = System.currentTimeMillis()
        cacheMetaDao.upsert(CacheMetaEntity("cover:$coverArtId", coverArtId, "cover", "assets", coverSize = coverSize, sizeBytes = data.size.toLong(), cachedAt = now, lastAccessedAt = now))
        return file
    }

    suspend fun resolveCoverImage(coverArtId: String): File? {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, false)
        val file = ImageCacheUtils.coverImageFile(dir, ImageCacheUtils.cacheId(coverArtId)) ?: return null
        cacheMetaDao.getByKey("cover:$coverArtId")?.let { cacheMetaDao.upsert(it.copy(lastAccessedAt = System.currentTimeMillis())) }
        return file
    }

    suspend fun enforceQuota(bytes: Long, protectedId: String? = null) {
        if (bytes <= 0) return
        val entries = cacheMetaDao.coversByLastAccess()
        var total = entries.sumOf { it.sizeBytes }
        entries.forEach { entry ->
            if (total > bytes && entry.id != protectedId) { deleteCoverImage(entry.id); total -= entry.sizeBytes }
        }
    }
    suspend fun deleteCoverImage(coverArtId: String): Boolean {
        val deleted = ImageCacheUtils.deleteCoverImageFiles(ImageCacheUtils.cacheDirectory(cacheDir, false), ImageCacheUtils.cacheId(coverArtId))
        cacheMetaDao.delete("cover:$coverArtId")
        return deleted
    }
    suspend fun clearCoverImages(): Int {
        val files = ImageCacheUtils.cacheDirectory(cacheDir, false).listFiles().orEmpty()
        files.forEach { it.delete() }
        cacheMetaDao.deleteByType("cover")
        return files.size
    }
    suspend fun getCoverImageSize(coverArtId: String): Pair<Long, String?>? {
        val file = ImageCacheUtils.coverImageFile(ImageCacheUtils.cacheDirectory(cacheDir, false), ImageCacheUtils.cacheId(coverArtId)) ?: return null
        return file.length() to cacheMetaDao.getByKey("cover:$coverArtId")?.coverSize
    }
}
