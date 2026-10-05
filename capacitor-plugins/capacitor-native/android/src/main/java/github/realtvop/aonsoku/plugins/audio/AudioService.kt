package github.realtvop.aonsoku.plugins.audio

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

data class AudioPlaybackSnapshot(
    val state: String = "idle",
    val requestId: String? = null,
    val songId: String? = null,
    val currentTimeSeconds: Double = 0.0,
    val durationSeconds: Double = 0.0,
    val bufferedTimeSeconds: Double = 0.0,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val volume: Double = 0.0,
)

data class AudioQueueSnapshot(
    val contextSongs: List<QueueSong> = emptyList(),
    val currentIndex: Int = 0,
    val sourceId: QueueSourceId? = null,
    val sourceName: String? = null,
    val userQueue: List<QueueSong> = emptyList(),
    val isInUserQueue: Boolean = false,
    val playedUserQueueHistory: List<QueueSong> = emptyList(),
    val isShuffleActive: Boolean = false,
    val repeatMode: String = "off",
    val currentSong: QueueSong? = null,
)

sealed interface AudioCommand {
    data object Play : AudioCommand
    data object Pause : AudioCommand
    data object TogglePlayPause : AudioCommand
    data object Stop : AudioCommand
    data object Next : AudioCommand
    data object Previous : AudioCommand
    data class Seek(val positionSeconds: Double) : AudioCommand
    data class SetVolume(val value: Double) : AudioCommand
    data class SetShuffle(val enabled: Boolean) : AudioCommand
    data class SetRepeat(val mode: String) : AudioCommand
}

sealed interface AudioCommandResult {
    data object Success : AudioCommandResult
    data class Failure(val code: String, val message: String) : AudioCommandResult
}

sealed interface AudioEvent {
    data class PlaybackStateChanged(val snapshot: AudioPlaybackSnapshot) : AudioEvent
    data class Progress(val snapshot: AudioPlaybackSnapshot) : AudioEvent
    data class BufferingChanged(val snapshot: AudioPlaybackSnapshot) : AudioEvent
    data class DurationChanged(val snapshot: AudioPlaybackSnapshot) : AudioEvent
    data class QueueStateChanged(
        val snapshot: AudioQueueSnapshot,
        val reason: String,
    ) : AudioEvent
    data class QueueContentsChanged(
        val snapshot: AudioQueueSnapshot,
        val reason: String,
    ) : AudioEvent
    data class Ended(val reason: String, val snapshot: AudioPlaybackSnapshot) : AudioEvent
    data class RemoteCommand(val command: String, val position: Double?) : AudioEvent
    data class RemoteControlCommand(
        val commandJson: String,
        val targetDeviceId: String?,
        val expectedGeneration: Int?,
    ) : AudioEvent
    data class SleepTimerEndOfTrack(val snapshot: AudioPlaybackSnapshot) : AudioEvent
    data class Error(val code: String, val message: String, val snapshot: AudioPlaybackSnapshot) : AudioEvent
    data class SystemVolumeChanged(val volume: Double) : AudioEvent
    data class RouteChanged(val reason: String) : AudioEvent
}

/**
 * Typed native playback boundary. Implementations must serialize player
 * mutations on the Android main thread; clients may collect each flow
 * independently and do not replace one another's listeners.
 */
interface AudioService {
    val playbackState: StateFlow<AudioPlaybackSnapshot>
    val queueState: StateFlow<AudioQueueSnapshot>
    val events: SharedFlow<AudioEvent>

    suspend fun execute(command: AudioCommand): AudioCommandResult
    fun requestAudioFocus(): Boolean
    fun getSystemVolume(): Double
    fun setSystemVolume(value: Double): Double
    fun setRequestId(requestId: String?)
}
