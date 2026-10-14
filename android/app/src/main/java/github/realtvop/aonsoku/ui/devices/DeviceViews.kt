package github.realtvop.aonsoku.ui.devices

import android.os.SystemClock
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Smartphone
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.coordination.DeviceGroups
import github.realtvop.aonsoku.data.coordination.DevicePlayback
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.t
import kotlinx.coroutines.delay

/** Phone, computer, TV, or anything else, by the platform a device registered with. */
fun deviceIcon(platform: String): ImageVector {
    val name = platform.lowercase()
    return when {
        listOf("ios", "android", "phone", "mobile").any { it in name } -> Icons.Rounded.Smartphone
        listOf("electron", "desktop", "mac", "windows", "linux").any { it in name } -> Icons.Rounded.Laptop
        "tv" in name -> Icons.Rounded.Tv
        else -> Icons.Rounded.Cast
    }
}

/**
 * The devices of the account in the sections of the device panel, worked out
 * again every second so that progress and "last online" stay current.
 */
@Composable
fun rememberDeviceGroups(): DeviceGroups {
    val coordination = LocalAppGraph.current.coordination
    val state by coordination.state.collectAsStateWithLifecycle()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(TICK_MS)
            now = System.currentTimeMillis()
        }
    }
    val thisDevice = t("settings.crossDevice.playback.thisDevice")
    return remember(state, now, thisDevice) {
        DevicePlayback.group(
            devices = state.devices,
            snapshots = state.snapshots,
            currentDeviceId = state.deviceId,
            controlledDeviceId = state.controlledDeviceId,
            thisDeviceName = thisDevice,
            now = now,
            nowElapsed = SystemClock.elapsedRealtime(),
        )
    }
}

/** A song another device plays, looked up here. */
sealed interface SongLookup {
    data object Loading : SongLookup

    data object Missing : SongLookup

    data class Found(val song: Song) : SongLookup
}

@Composable
fun rememberSongLookup(songId: String?): State<SongLookup> {
    val library = LocalAppGraph.current.library
    return produceState<SongLookup>(SongLookup.Loading, songId) {
        if (songId.isNullOrEmpty()) {
            value = SongLookup.Missing
            return@produceState
        }
        val song = runSuspendCatching { library.knownSong(songId) }.getOrNull()
        value = if (song != null) SongLookup.Found(song) else SongLookup.Missing
    }
}

/** The title to show for the song while it is looked up, found, or not found. */
@Composable
fun SongLookup.title(): String = when (this) {
    SongLookup.Loading -> t("settings.crossDevice.playback.fetchingSong")
    SongLookup.Missing -> t("settings.crossDevice.playback.unknownTrack")
    is SongLookup.Found -> song.title
}

private const val TICK_MS = 1_000L
