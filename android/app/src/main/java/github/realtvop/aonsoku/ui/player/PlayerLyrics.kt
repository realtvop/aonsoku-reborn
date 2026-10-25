package github.realtvop.aonsoku.ui.player

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.lyrics.Lyrics
import github.realtvop.aonsoku.data.lyrics.LyricsData
import github.realtvop.aonsoku.data.lyrics.LyricsParser
import github.realtvop.aonsoku.data.lyrics.LyricsSong
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.settings.SelectedCustomLyrics
import kotlin.math.roundToLong

/** The lyrics of the song in the player, as far as they are known. */
@Immutable
data class PlayerLyrics(
    /** What the lyrics are remembered by; null until the song is identified. */
    val song: LyricsSong? = null,
    val loading: Boolean = false,
    val lyrics: Lyrics? = null,
    /** What the user chose for this song: an entry, an offset, or no lyrics. */
    val choice: SelectedCustomLyrics? = null,
) {
    /** False once it is known that there is nothing to show. */
    val mayExist: Boolean get() = loading || lyrics != null

    val disabled: Boolean get() = choice?.disabled == true

    /** Positive shows the lyrics later than their timestamps say. */
    val offsetMs: Long get() = ((choice?.offset ?: 0.0) * 1000).roundToLong()
}

/**
 * Loads the lyrics of [song] and follows what decides them: the lyric
 * settings, the choice made for the song, and the server coming into reach.
 */
@Composable
fun rememberPlayerLyrics(song: QueueSong?): PlayerLyrics {
    val graph = LocalAppGraph.current
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val online by graph.network.isOnline.collectAsStateWithLifecycle()
    val revision by graph.lyrics.revision.collectAsStateWithLifecycle()

    val identified by produceState<LyricsSong?>(initialValue = null, song?.id) {
        value = null
        value = song?.let { graph.lyrics.identify(graph.player.songFor(it)) }
    }
    val current = identified?.takeIf { it.id == song?.id }
    val lyricsSettings = settings.lyrics
    val choice = current?.let { lyricsSettings.selected[it.key] }

    var loaded by remember { mutableStateOf<Pair<LyricsSong, LyricsData>?>(null) }
    LaunchedEffect(
        current,
        lyricsSettings.sourcePriority,
        lyricsSettings.customServerEnabled,
        lyricsSettings.customServerUrl,
        lyricsSettings.customServerPassword,
        settings.lrcLibEnabled,
        choice?.key,
        choice?.disabled,
        online,
        revision,
    ) {
        // Another song starts empty; the same song keeps its lyrics while they are read again.
        if (loaded?.first != current) loaded = null
        if (current != null) loaded = current to graph.lyrics.load(current)
    }

    val data = loaded?.takeIf { it.first == current }?.second
    val durationMs = current?.durationMs
    val lyrics = remember(data, lyricsSettings.showTranslation, durationMs) {
        data?.let { LyricsParser.resolve(it, lyricsSettings.showTranslation, durationMs) }
    }
    return PlayerLyrics(
        song = current,
        loading = song != null && data == null,
        lyrics = lyrics,
        choice = choice,
    )
}
