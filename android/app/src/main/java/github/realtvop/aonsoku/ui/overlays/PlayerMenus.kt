package github.realtvop.aonsoku.ui.overlays

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.TimerOff
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.SleepTimerState
import github.realtvop.aonsoku.ui.components.ActionDivider
import github.realtvop.aonsoku.ui.components.ActionItem
import github.realtvop.aonsoku.ui.components.ActionSheet
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.SheetHeader
import github.realtvop.aonsoku.ui.components.SheetTitle
import github.realtvop.aonsoku.ui.components.queueSongCoverArt
import github.realtvop.aonsoku.ui.components.rememberExpandedSheetState
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.ArtistRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import kotlinx.coroutines.delay
import java.util.Locale

/** Sleep timer lengths offered by the web app, in minutes. */
private val SleepTimerPresets = listOf(5, 10, 15, 30, 45, 60)

/** Options of the song that is playing: playlist, sleep timer, links, and details. */
@Composable
fun CurrentSongMenuSheet(controller: OverlayController) {
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val playerState by graph.player.state.collectAsStateWithLifecycle()
    val timer by graph.player.sleepTimer.collectAsStateWithLifecycle()
    val queueSong = playerState.current?.takeIf { !playerState.isRadio }
    if (queueSong == null) {
        LaunchedEffect(Unit) { controller.dismiss() }
        return
    }
    val song = remember(queueSong) { graph.player.songFor(queueSong) }

    ActionSheet(
        onDismiss = controller::dismiss,
        header = {
            SheetHeader(
                title = song.title,
                subtitle = song.artistLabel,
                art = queueSongCoverArt(queueSong),
                kind = CoverKind.Song,
            )
        },
    ) {
        ActionItem(
            icon = Icons.Rounded.Add,
            label = t("options.playlist.add"),
            onClick = {
                controller.show(Overlay.AddToPlaylist(song.title, songIds = listOf(song.id)))
            },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.Timer,
            label = t("player.sleepTimer.title"),
            trailingText = sleepTimerStatus(timer),
            onClick = { controller.show(Overlay.SleepTimer) },
        )
        if (!song.artistId.isNullOrEmpty() || !song.albumId.isNullOrEmpty()) {
            ActionDivider()
            song.artistId?.takeIf { it.isNotEmpty() }?.let { artistId ->
                ActionItem(
                    icon = Icons.Rounded.Person,
                    label = t("options.goto.artist"),
                    onClick = { navigator.open(ArtistRoute(artistId)) },
                )
            }
            song.albumId?.takeIf { it.isNotEmpty() }?.let { albumId ->
                ActionItem(
                    icon = Icons.Rounded.Album,
                    label = t("options.goto.album"),
                    onClick = { navigator.open(AlbumRoute(albumId)) },
                )
            }
        }
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.Info,
            label = t("options.info"),
            onClick = { controller.show(Overlay.SongInfo(song.id)) },
        )
    }
}

/** Start a sleep timer, or see and cancel the one that is running. */
@Composable
fun SleepTimerSheet(controller: OverlayController) {
    val player = LocalAppGraph.current.player
    val timer by player.sleepTimer.collectAsStateWithLifecycle()

    ActionSheet(onDismiss = controller::dismiss) {
        SheetTitle(t("player.sleepTimer.title"))
        if (timer.active) {
            Text(
                text = sleepTimerStatus(timer).orEmpty(),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 8.dp),
            )
            ActionDivider()
            ActionItem(
                icon = Icons.Rounded.TimerOff,
                label = t("player.sleepTimer.cancel"),
                destructive = true,
                onClick = player::cancelSleepTimer,
            )
        } else {
            for (minutes in SleepTimerPresets) {
                ActionItem(
                    icon = Icons.Rounded.Timer,
                    label = t("player.sleepTimer.minutes", "count" to minutes),
                    onClick = { player.startSleepTimer(minutes * 60) },
                )
            }
            ActionDivider()
            ActionItem(
                icon = Icons.Rounded.MusicNote,
                label = t("player.sleepTimer.endOfTrack"),
                onClick = player::startEndOfTrackTimer,
            )
        }
    }
}

/** What the running sleep timer waits for, counting down; null without a timer. */
@Composable
private fun sleepTimerStatus(timer: SleepTimerState): String? {
    if (!timer.active) return null
    if (timer.endOfTrack) return t("player.sleepTimer.endOfTrack")
    val remaining by produceState(timer.remainingSeconds(), timer) {
        while (true) {
            value = timer.remainingSeconds()
            delay(1_000)
        }
    }
    val clock = String.format(Locale.US, "%d:%02d", remaining / 60, remaining % 60)
    return t("player.sleepTimer.remaining", "time" to clock)
}

/** How strongly the artwork color tints the full-screen player. */
@Composable
fun PlayerColorsSheet(controller: OverlayController) {
    val settings = LocalAppGraph.current.settings
    val label = t("settings.appearance.colors.queue.intensity")
    val slider = remember {
        SliderState(
            settings.current.songColorIntensity,
            INTENSITY_STEPS,
            INTENSITY_MIN..INTENSITY_MAX,
        )
    }

    ModalBottomSheet(
        onDismissRequest = controller::dismiss,
        sheetState = rememberExpandedSheetState(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 24.dp),
        ) {
            SheetTitle(label)
            Slider(
                state = slider,
                onValueChange = { value ->
                    slider.value = value
                    settings.update { it.copy(songColorIntensity = value) }
                },
                modifier = Modifier
                    .padding(horizontal = 24.dp)
                    .semantics { contentDescription = label },
            )
        }
    }
}

private const val INTENSITY_MIN = 0.3f
private const val INTENSITY_MAX = 1f

/** Stops between the ends for increments of 0.05. */
private const val INTENSITY_STEPS = 13
