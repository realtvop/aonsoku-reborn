package github.realtvop.aonsoku.data.lyrics

import github.realtvop.aonsoku.data.api.SubsonicApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest

/**
 * Lyrics kept on the device: the entry the user chose for a song, which stays
 * until it is replaced, and what the sources answered earlier, which is a
 * cache the system may clear.
 */
class LyricsStore(private val choices: File, private val cache: File) {
    /** The lyrics chosen for the song with [songKey]. */
    suspend fun choice(songKey: String): LyricsText? = withContext(Dispatchers.IO) {
        val lyrics = runCatching { choiceFile(songKey, LYRICS).readText() }.getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?: return@withContext null
        val romaji = runCatching { choiceFile(songKey, ROMAJI).readText() }.getOrNull()
        LyricsText(lyrics, romaji?.takeIf { it.isNotBlank() })
    }

    /** Throws when the lyrics cannot be written. */
    suspend fun saveChoice(songKey: String, lyrics: String, romaji: String?) = withContext(Dispatchers.IO) {
        choices.mkdirs()
        choiceFile(songKey, LYRICS).writeText(lyrics)
        // A romanization belongs to the lyrics it came with.
        if (romaji.isNullOrBlank()) choiceFile(songKey, ROMAJI).delete() else choiceFile(songKey, ROMAJI).writeText(romaji)
    }

    suspend fun deleteChoices(songKeys: Collection<String>) = withContext(Dispatchers.IO) {
        for (key in songKeys) {
            choiceFile(key, LYRICS).delete()
            choiceFile(key, ROMAJI).delete()
        }
    }

    /** An earlier answer for [song]; [variant] names the settings it was found with. */
    suspend fun cached(song: LyricsSong, variant: String): LyricsText? = withContext(Dispatchers.IO) {
        runCatching {
            SubsonicApi.json.decodeFromString(LyricsText.serializer(), cacheFile(song, variant).readText())
        }.getOrNull()?.takeIf { it.value.isNotBlank() }
    }

    suspend fun cache(song: LyricsSong, variant: String, text: LyricsText) {
        withContext(Dispatchers.IO) {
            runCatching {
                val file = cacheFile(song, variant)
                file.parentFile?.mkdirs()
                file.writeText(SubsonicApi.json.encodeToString(LyricsText.serializer(), text))
            }
        }
    }

    /** Forgets every cached answer for [song], whatever settings it was found with. */
    suspend fun clearCache(song: LyricsSong) {
        withContext(Dispatchers.IO) { cacheDirectory(song).deleteRecursively() }
    }

    suspend fun clearCache() {
        withContext(Dispatchers.IO) { cache.deleteRecursively() }
    }

    suspend fun clearAccount() = withContext(Dispatchers.IO) {
        check(!choices.exists() || choices.deleteRecursively()) { "Could not clear selected lyrics" }
        check(!cache.exists() || cache.deleteRecursively()) { "Could not clear cached lyrics" }
    }

    private fun choiceFile(songKey: String, kind: String): File = File(choices, "${digest(songKey)}.$kind")

    private fun cacheDirectory(song: LyricsSong): File =
        File(cache, digest(listOf(song.artist, song.title, song.album).joinToString(SEPARATOR)))

    private fun cacheFile(song: LyricsSong, variant: String): File =
        File(cacheDirectory(song), "${digest(variant)}.json")

    /** Keys hold paths and titles, so files are named by a digest of them. */
    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray())
        .joinToString("") { "%02x".format(it) }
        .take(DIGEST_LENGTH)

    private companion object {
        const val LYRICS = "lrc"
        const val ROMAJI = "romaji.lrc"
        const val SEPARATOR = "\u001f"
        const val DIGEST_LENGTH = 40
    }
}
