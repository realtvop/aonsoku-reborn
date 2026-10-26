package github.realtvop.aonsoku.data.lyrics

import android.util.LruCache
import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.NetworkMonitor
import github.realtvop.aonsoku.data.api.ApiException
import github.realtvop.aonsoku.data.api.SubsonicApi
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.settings.AppSettings
import github.realtvop.aonsoku.settings.LyricsSettings
import github.realtvop.aonsoku.settings.LyricsSource
import github.realtvop.aonsoku.settings.SelectedCustomLyrics
import github.realtvop.aonsoku.settings.SettingsRepository
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.roundToInt

/**
 * Finds the lyrics of a song and keeps the choices made per song: which entry
 * of a custom lyrics server to use, a timing offset, or no lyrics at all.
 *
 * Structured lyrics come from the library, which keeps them once they were
 * shown or downloaded, or from the server. Lyrics as text come from the
 * sources in the order of the settings: the music server, LRCLIB, a custom
 * lyrics server.
 */
class LyricsRepository(
    private val api: SubsonicApi,
    private val library: LibraryService,
    private val songs: LibraryRepository,
    private val settings: SettingsRepository,
    private val network: NetworkMonitor,
    private val store: LyricsStore,
    private val sources: LyricsSources,
    /** "navidrome", "subsonic", or "lms". */
    private val serverType: () -> String?,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val _revision = MutableStateFlow(0)

    /** Changes when lyrics that were loaded before may be different now. */
    val revision: StateFlow<Int> = _revision.asStateFlow()

    /** Lookups that found nothing a moment ago, so reopening the player does not repeat them. */
    private val misses = LruCache<String, Long>(MISS_CAPACITY)

    /**
     * What lyrics of [song] are looked up and remembered by. Queue entries do
     * not carry the file path, which the library knows.
     */
    suspend fun identify(song: Song): LyricsSong {
        val full = if (song.path != null) {
            song
        } else {
            runSuspendCatching { songs.localSong(song.id) }.getOrNull() ?: song
        }
        return LyricsSong(
            id = song.id,
            artist = full.artist ?: song.artist.orEmpty(),
            title = full.title.ifEmpty { song.title },
            album = (full.album ?: song.album).orEmpty(),
            durationSeconds = (full.duration.takeIf { it > 0 } ?: song.duration).toDouble(),
            path = full.path.orEmpty(),
        )
    }

    /** Everything the sources have for [song]; empty when lyrics are turned off for it. */
    suspend fun load(song: LyricsSong): LyricsData = coroutineScope {
        val current = settings.current
        val choice = current.lyrics.selected[song.key]
        if (choice?.disabled == true) return@coroutineScope LyricsData()
        val structured = async { structured(song.id) }
        val text = async { text(song, current, choice) }
        LyricsData(structured.await(), text.await())
    }

    /**
     * The structured lyrics of a song: the copy in the library, or the
     * server's, which is then kept there for offline playback.
     */
    suspend fun structured(songId: String): List<StructuredLyrics> {
        runSuspendCatching { library.getLyrics(songId)?.content }.getOrNull()
            ?.let { SubsonicApi.decodeList<StructuredLyrics>(it) }
            ?.takeIf { it.isNotEmpty() }
            ?.let { return it }

        val missKey = "$STRUCTURED_MISS$songId"
        if (!network.online || isRecentMiss(missKey)) return emptyList()
        val answer = runSuspendCatching { api.getLyricsBySongId(songId) }
        val raw = answer.getOrNull()?.get("structuredLyrics").asArray()
        val tracks = raw?.let { SubsonicApi.decodeList<StructuredLyrics>(it.toString()) }.orEmpty()
        if (raw == null || tracks.isEmpty()) {
            // Servers without the endpoint answer with an error for every song.
            if (answer.exceptionOrNull() !is ApiException.NetworkUnreachable) rememberMiss(missKey)
            return emptyList()
        }
        runSuspendCatching { library.storeLyrics(songId, raw.toString(), tracks.first().synced) }
        return tracks
    }

    private suspend fun text(
        song: LyricsSong,
        current: AppSettings,
        choice: SelectedCustomLyrics?,
    ): LyricsText? {
        val order = enabledSources(current.lyrics)
        val variant = variantOf(song, current.lyrics, order, choice)
        store.cached(song, variant)?.let { return it }

        val missKey = textMissPrefix(song) + variant
        if (isRecentMiss(missKey)) return null
        var everySourceAnswered = true
        for (source in order) {
            val answer = runSuspendCatching { fromSource(source, song, current, choice) }
            if (answer.isFailure) everySourceAnswered = false
            val found = answer.getOrNull()?.takeIf { it.value.isNotBlank() } ?: continue
            store.cache(song, variant, found)
            return found
        }
        if (everySourceAnswered && network.online) rememberMiss(missKey)
        return null
    }

    private suspend fun fromSource(
        source: LyricsSource,
        song: LyricsSong,
        current: AppSettings,
        choice: SelectedCustomLyrics?,
    ): LyricsText? = when (source) {
        LyricsSource.Navidrome -> when {
            !network.online -> null
            else -> api.getLyrics(song.artist, song.title)?.get("value")
                ?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }
                ?.let { LyricsText(LyricsSources.normalize(it)) }
        }
        LyricsSource.LrcLib -> when {
            !network.online || !current.lrcLibEnabled -> null
            else -> sources.fromLrcLib(song, lrcLibArtist(song))
        }
        LyricsSource.Custom -> {
            val chosenKey = choice?.key?.takeIf { it.isNotEmpty() }
            val chosen = chosenKey?.let { store.choice(song.key) }
            val server = customServer(current.lyrics)
            when {
                chosen != null -> chosen
                server == null || !network.online -> null
                else -> sources.fromCustomServer(song, server, chosenKey)
            }
        }
    }

    /**
     * LMS joins every artist of a song into one string, such as "Cartoon,
     * Jeja, Daniel Levi", while LRCLIB matches on a single artist.
     */
    private fun lrcLibArtist(song: LyricsSong): String =
        if (serverType() == SERVER_LMS) song.artist.substringBefore(',') else song.artist

    /** The entries the custom lyrics server offers for a title and an artist. */
    suspend fun candidates(title: String, artist: String): List<LyricsCandidate> {
        val server = customServer(settings.current.lyrics) ?: return emptyList()
        return runSuspendCatching { sources.candidates(server, title, artist) }.getOrDefault(emptyList())
    }

    /**
     * Uses [candidate], the entry at [index] of a search, for [song] from now
     * on. [title] and [artist] are what was searched for, as a name for
     * entries that have none. Throws when the lyrics cannot be kept.
     */
    suspend fun choose(
        song: LyricsSong,
        candidate: LyricsCandidate,
        index: Int,
        title: String = "",
        artist: String = "",
    ) {
        val lyrics = candidate.lyrics?.trim().orEmpty()
        if (lyrics.isEmpty()) return
        store.saveChoice(song.key, lyrics, candidate.romaji?.trim())
        // The server may have changed the lyrics behind the same entry.
        store.clearCache(song)
        changeChoices { selected ->
            val entry = SelectedCustomLyrics(
                key = candidate.key(index),
                title = candidate.title?.takeIf { it.isNotEmpty() } ?: title.ifEmpty { song.title },
                artist = candidate.artist?.takeIf { it.isNotEmpty() } ?: artist.ifEmpty { song.artist },
                // A timing offset set for the song stays.
                offset = selected[song.key]?.offset ?: 0.0,
                hasRomaji = candidate.hasRomaji,
            )
            selected.with(song.key, entry)
        }
        reloaded(song)
    }

    /** Turns the lyrics of [song] off, or back to what the sources find. */
    suspend fun setDisabled(song: LyricsSong, disabled: Boolean) {
        store.deleteChoices(listOf(song.key))
        changeChoices { selected ->
            if (disabled) selected.with(song.key, SelectedCustomLyrics(disabled = true)) else selected - song.key
        }
        reloaded(song)
    }

    /** Shifts the lyrics of [song] by [seconds]; positive shows them later. */
    suspend fun setOffset(song: LyricsSong, seconds: Double) {
        val offset = (seconds.coerceIn(OFFSET_MIN, OFFSET_MAX) * OFFSET_PRECISION).roundToInt() / OFFSET_PRECISION
        changeChoices { selected ->
            val existing = selected[song.key]
            when {
                offset != 0.0 && existing != null -> selected + (song.key to existing.copy(offset = offset))
                offset != 0.0 -> selected.with(song.key, SelectedCustomLyrics(offset = offset))
                existing == null -> selected
                // Nothing else was chosen for the song.
                existing.key.isEmpty() && !existing.disabled -> selected - song.key
                else -> selected + (song.key to existing.copy(offset = 0.0))
            }
        }
    }

    /** Forgets what the sources answered, for example when the account changes. */
    suspend fun clearCache() {
        store.clearCache()
        misses.evictAll()
    }

    suspend fun clearAccount() {
        store.clearAccount()
        settings.update { it.copy(lyrics = it.lyrics.copy(selected = emptyMap())) }
        misses.evictAll()
        _revision.update { it + 1 }
    }

    /** Applies [change] and drops the lyrics of the choices it pushed out. */
    private suspend fun changeChoices(
        change: (Map<String, SelectedCustomLyrics>) -> Map<String, SelectedCustomLyrics>,
    ) {
        val before = settings.current.lyrics.selected.keys
        settings.update { it.copy(lyrics = it.lyrics.copy(selected = change(it.lyrics.selected))) }
        val dropped = before - settings.current.lyrics.selected.keys
        if (dropped.isNotEmpty()) store.deleteChoices(dropped)
    }

    /** Adds or moves [key] to the end and keeps the newest [MAX_CHOICES] entries. */
    private fun Map<String, SelectedCustomLyrics>.with(
        key: String,
        entry: SelectedCustomLyrics,
    ): Map<String, SelectedCustomLyrics> {
        val next = LinkedHashMap(this)
        next.remove(key)
        next[key] = entry
        return next.entries.toList().takeLast(MAX_CHOICES).associate { it.key to it.value }
    }

    private fun reloaded(song: LyricsSong) {
        val prefix = textMissPrefix(song)
        misses.snapshot().keys.filter { it.startsWith(prefix) }.forEach(misses::remove)
        _revision.update { it + 1 }
    }

    /** The sources in the order of the settings; a custom server only once it is set up. */
    private fun enabledSources(lyrics: LyricsSettings): List<LyricsSource> {
        val order = (lyrics.sourcePriority + LyricsSource.entries).distinct()
        return if (customServer(lyrics) == null) order - LyricsSource.Custom else order
    }

    private fun customServer(lyrics: LyricsSettings): CustomLyricsServer? =
        lyrics.customServerUrl.trim()
            .takeIf { lyrics.customServerEnabled && it.isNotEmpty() }
            ?.let { CustomLyricsServer(it, lyrics.customServerPassword) }

    /** Names the settings an answer was found with; another setting is another answer. */
    private fun variantOf(
        song: LyricsSong,
        lyrics: LyricsSettings,
        order: List<LyricsSource>,
        choice: SelectedCustomLyrics?,
    ): String = listOf(
        song.durationParam.orEmpty(),
        song.path,
        if (lyrics.preferSynced) "synced" else "plain",
        order.joinToString(",") { it.name },
        if (lyrics.customServerEnabled) lyrics.customServerUrl.trim() else "off",
        choice?.key?.takeIf { it.isNotEmpty() } ?: "auto",
    ).joinToString(":")

    private fun textMissPrefix(song: LyricsSong): String = "$TEXT_MISS${song.key}:"

    private fun isRecentMiss(key: String): Boolean {
        val at = misses.get(key) ?: return false
        return now() - at < MISS_TTL_MS
    }

    private fun rememberMiss(key: String) {
        misses.put(key, now())
    }

    /** Tolerates servers that collapse a one-element array into an object. */
    private fun JsonElement?.asArray(): JsonArray? = when (this) {
        is JsonArray -> this
        is JsonObject -> JsonArray(listOf(this))
        else -> null
    }

    companion object {
        /** How many songs keep a choice; the oldest ones make room. */
        const val MAX_CHOICES = 50
        const val OFFSET_MIN = -2.0
        const val OFFSET_MAX = 2.0
        const val OFFSET_STEP = 0.1
        private const val OFFSET_PRECISION = 10.0

        private const val MISS_CAPACITY = 128
        private const val MISS_TTL_MS = 5 * 60 * 1000L
        private const val STRUCTURED_MISS = "structured:"
        private const val TEXT_MISS = "text:"
        private const val SERVER_LMS = "lms"
    }
}
