package github.realtvop.aonsoku.plugins.data.image
import android.util.Base64
import java.io.File
object ImageCacheUtils {
    val cachedImageExtensions = listOf("jpg", "png", "webp", "gif")
    fun cacheId(forCoverArtId: String) = Base64.encodeToString(forCoverArtId.toByteArray(), Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
    fun cacheDirectory(cacheDir: File, createIfNeeded: Boolean): File { val d = File(cacheDir, "ImageCache"); if (createIfNeeded) d.mkdirs(); return d }
    fun fileExtension(forContentType: String): String = when (forContentType.substringBefore(";").trim().lowercase()) { "image/jpeg", "image/jpg" -> "jpg"; "image/png" -> "png"; "image/webp" -> "webp"; "image/gif" -> "gif"; else -> "jpg" }
    fun coverImageFile(dir: File, cacheId: String): File? = cachedImageExtensions.asSequence().map { File(dir, "$cacheId.$it") }.firstOrNull { it.exists() }
    fun deleteCoverImageFiles(dir: File, cacheId: String): Boolean {
        var deleted = false
        cachedImageExtensions.forEach { ext ->
            val file = File(dir, "$cacheId.$ext")
            if (file.exists() && file.delete()) deleted = true
        }
        return deleted
    }
}
