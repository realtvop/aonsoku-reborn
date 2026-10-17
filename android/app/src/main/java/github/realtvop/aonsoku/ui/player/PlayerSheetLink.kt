package github.realtvop.aonsoku.ui.player

import androidx.compose.runtime.staticCompositionLocalOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * What the activity and the player tell each other, on the main thread: the
 * player says whether it shows this device's volume, and the activity asks
 * it to open when the playback notification or the system's media controls
 * were tapped.
 */
class PlayerSheetLink {
    private var volumeBars = 0

    /**
     * Whether a volume bar of this device's playback is on screen. The volume
     * keys then change the volume without the system's volume panel, which
     * would cover the bar (the web app hides it the same way).
     */
    val showsVolume: Boolean get() = volumeBars > 0

    fun volumeBarShown() {
        volumeBars++
    }

    fun volumeBarHidden() {
        volumeBars = maxOf(0, volumeBars - 1)
    }

    private val _openRequested = MutableStateFlow(false)

    /** Whether the player was asked to open and has not opened yet. */
    val openRequested: StateFlow<Boolean> = _openRequested.asStateFlow()

    fun requestOpen() {
        _openRequested.value = true
    }

    fun consumeOpenRequest() {
        _openRequested.value = false
    }
}

val LocalPlayerSheetLink = staticCompositionLocalOf { PlayerSheetLink() }
