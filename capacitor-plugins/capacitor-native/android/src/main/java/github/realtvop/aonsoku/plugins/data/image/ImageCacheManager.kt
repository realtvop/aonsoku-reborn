package github.realtvop.aonsoku.plugins.data.image

import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.data.db.dao.CacheMetaDao
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

class ImageCacheManager(private val cacheDir: File, private val cacheMetaDao: CacheMetaDao) {
    private val client = OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).build()

    suspend fun downloadCoverImage(coverArtId: String, size: String, credentials: ServerCredentials): File {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, true); val cid = ImageCacheUtils.cacheId(coverArtId)
        ImageCacheUtils.deleteCoverImageFiles(dir, cid)
        val p = SubsonicAuthBuilder.buildQueryParams(credentials.username, credentials.password, credentials.authType, credentials.protocolVersion).toMutableMap().apply { put("id", coverArtId); put("size", size) }
        val url = "${credentials.serverUrl.trimEnd('/')}/rest/getCoverArt?${p.entries.joinToString("&") { (k, v) -> "${java.net.URLEncoder.encode(k, "UTF-8")}=${java.net.URLEncoder.encode(v, "UTF-8")}" }}"
        val resp = client.newCall(Request.Builder().url(url).get().build()).execute()
        if (!resp.isSuccessful) throw ImageCacheError.DownloadFailed(Exception("HTTP ${resp.code}"))
        val ct = resp.header("Content-Type", "image/jpeg") ?: "image/jpeg"; val ext = ImageCacheUtils.fileExtension(ct)
        val data = resp.body?.bytes() ?: throw ImageCacheError.DownloadFailed(Exception("Empty body"))
        val file = File(dir, "$cid.$ext"); file.writeBytes(data)
        val now = System.currentTimeMillis()
        cacheMetaDao.upsert(CacheMetaEntity("cover:$coverArtId", coverArtId, "cover", "explicit", coverSize = size, sizeBytes = data.size.toLong(), cachedAt = now, lastAccessedAt = now))
        return file
    }

    suspend fun downloadAvatar(username: String, size: String, credentials: ServerCredentials): File {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, true); val cid = ImageCacheUtils.cacheId(username)
        ImageCacheUtils.deleteCoverImageFiles(dir, cid)
        val p = SubsonicAuthBuilder.buildQueryParams(credentials.username, credentials.password, credentials.authType, credentials.protocolVersion).toMutableMap().apply { put("username", username); put("size", size) }
        val url = "${credentials.serverUrl.trimEnd('/')}/rest/getAvatar?${p.entries.joinToString("&") { (k, v) -> "${java.net.URLEncoder.encode(k, "UTF-8")}=${java.net.URLEncoder.encode(v, "UTF-8")}" }}"
        val resp = client.newCall(Request.Builder().url(url).get().build()).execute()
        if (!resp.isSuccessful) throw ImageCacheError.DownloadFailed(Exception("HTTP ${resp.code}"))
        val ct = resp.header("Content-Type", "image/jpeg") ?: "image/jpeg"; val ext = ImageCacheUtils.fileExtension(ct)
        val data = resp.body?.bytes() ?: throw ImageCacheError.DownloadFailed(Exception("Empty body"))
        val file = File(dir, "$cid.$ext"); file.writeBytes(data)
        val now = System.currentTimeMillis()
        cacheMetaDao.upsert(CacheMetaEntity("cover:$username", username, "cover", "explicit", coverSize = size, sizeBytes = data.size.toLong(), cachedAt = now, lastAccessedAt = now))
        return file
    }

    suspend fun storeCoverImage(coverArtId: String, data: ByteArray, contentType: String, coverSize: String): File {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, true); val cid = ImageCacheUtils.cacheId(coverArtId); val ext = ImageCacheUtils.fileExtension(contentType)
        val file = File(dir, "$cid.$ext"); ImageCacheUtils.deleteCoverImageFiles(dir, cid); file.writeBytes(data)
        val now = System.currentTimeMillis()
        cacheMetaDao.upsert(CacheMetaEntity("cover:$coverArtId", coverArtId, "cover", "explicit", coverSize = coverSize, sizeBytes = data.size.toLong(), cachedAt = now, lastAccessedAt = now))
        return file
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
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, false); if (!dir.exists()) return 0
        val files = dir.listFiles() ?: return 0; files.forEach { it.delete() }
        try { cacheMetaDao.deleteByType("cover") } catch (_: Exception) {}; return files.size
    }

    suspend fun getCoverImageSize(coverArtId: String): Pair<Long, String?>? {
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, false); val cid = ImageCacheUtils.cacheId(coverArtId)
        val f = ImageCacheUtils.coverImageFile(dir, cid) ?: return null; if (!f.exists()) return null
        val r = try { cacheMetaDao.getByKey("cover:$coverArtId") } catch (_: Exception) { null }
        return Pair(f.length(), r?.coverSize)
    }
}
