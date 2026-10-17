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

    /** The note next to an audio file that says what it is. */
    fun metadataFile(directory: File, songId: String): File = File(directory, "${cacheId(songId)}.json")

    /** The song a cache file name stands for; null when the name is not one of ours. */
    fun songId(cacheId: String): String? {
        if (cacheId.isEmpty()) return null
        val bytes = try {
            Base64.decode(cacheId, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        } catch (_: Throwable) {
            // Fallback for JVM unit tests where android.util.Base64 is stubbed
            try {
                java.util.Base64.getUrlDecoder().decode(cacheId)
            } catch (_: IllegalArgumentException) {
                null
            }
        } ?: return null
        val songId = String(bytes, Charsets.UTF_8)
        // Only names this app could have written: decoding must round-trip.
        return songId.takeIf { it.isNotEmpty() && cacheId(it) == cacheId }
    }

    /** The cached audio of [songId] in the first of [directories] that has it. */
    fun findFile(directories: List<File>, songId: String): File? {
        val cacheId = cacheId(songId)
        for (directory in directories) {
            if (!directory.isDirectory) continue
            for (extension in AUDIO_EXTENSIONS) {
                val file = File(directory, "$cacheId.$extension")
                if (file.exists()) return file
            }
        }
        return null
    }

    /** Deletes every cached copy of [songId] and its note; true when a file went. */
    fun deleteFiles(directories: List<File>, songId: String): Boolean {
        val cacheId = cacheId(songId)
        var deleted = false
        for (directory in directories) {
            for (extension in AUDIO_EXTENSIONS) {
                val file = File(directory, "$cacheId.$extension")
                if (file.exists() && file.delete()) deleted = true
            }
            File(directory, "$cacheId.json").delete()
        }
        return deleted
    }

    /** The extensions [fileExtension] gives to audio files. */
    val AUDIO_EXTENSIONS = listOf("mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "audio")

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
