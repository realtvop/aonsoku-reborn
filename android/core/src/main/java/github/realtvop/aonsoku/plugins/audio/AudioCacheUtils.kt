package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import android.util.Base64
import java.io.File

object AudioCacheUtils {
    const val CACHE_DIRECTORY_NAME = "AudioCache"

    fun cacheId(songId: String): String {
        val bytes = songId.toByteArray(Charsets.UTF_8)
        val base64Str = try {
            Base64.encodeToString(bytes, Base64.NO_WRAP)
        } catch (_: Throwable) {
            // Fallback for JVM unit tests where android.util.Base64 is stubbed
            java.util.Base64.getEncoder().encodeToString(bytes)
        }
        return base64Str
            .replace("+", "-")
            .replace("/", "_")
            .replace("=", "")
    }

    fun getCacheDirectory(context: Context, createIfNeeded: Boolean = false): File {
        val directory = File(context.filesDir, CACHE_DIRECTORY_NAME)
        if (createIfNeeded && !directory.exists()) {
            directory.mkdirs()
        }
        return directory
    }

    fun getSecondaryCacheDirectory(context: Context): File {
        return File(context.cacheDir, CACHE_DIRECTORY_NAME)
    }

    fun getMetadataFile(context: Context, songId: String): File {
        val dir = getCacheDirectory(context, createIfNeeded = true)
        return File(dir, "${cacheId(songId)}.json")
    }

    fun fileExtension(contentType: String): String {
        val normalized = contentType
            .split(";", limit = 2)
            .firstOrNull()
            ?.trim()
            ?.lowercase() ?: ""

        return when (normalized) {
            "audio/mpeg", "audio/mp3" -> "mp3"
            "audio/flac", "audio/x-flac" -> "flac"
            "audio/mp4", "audio/m4a", "audio/x-m4a" -> "m4a"
            "audio/aac" -> "aac"
            "audio/ogg", "application/ogg" -> "ogg"
            "audio/opus" -> "opus"
            "audio/wav", "audio/x-wav" -> "wav"
            else -> "audio"
        }
    }
}
