package github.realtvop.aonsoku.plugins.audio

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject

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

data class AudioRemotePlaybackSnapshot(
    val songId: String?,
    val sourceName: String?,
    val isPlaying: Boolean,
    val progressSeconds: Double,
    val durationSeconds: Double,
    val isShuffleActive: Boolean,
    val repeatMode: String,
    val volume: Double?,
    val targetDeviceId: String,
    val expectedGeneration: Int,
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
    data class SetSleepTimer(val seconds: Double, val mode: String) : AudioCommand
    data object CancelSleepTimer : AudioCommand
    data class PlaySongById(val songId: String) : AudioCommand
    data class PlayAlbumById(val albumId: String, val index: Int, val shuffle: Boolean) : AudioCommand
    data class PlayPlaylistById(val playlistId: String, val index: Int, val shuffle: Boolean) : AudioCommand
    data class PlaySongsById(val songIds: List<String>, val index: Int) : AudioCommand
    data class AddSongsById(val songIds: List<String>, val position: String) : AudioCommand
    data class SetContextQueue(
        val songs: List<QueueSong>,
        val currentIndex: Int,
        val autoplay: Boolean,
        val startTime: Double?,
        val sourceId: QueueSourceId?,
        val sourceName: String?,
        val repeatMode: String?,
    ) : AudioCommand
    data class UpdateContextQueue(val songs: List<QueueSong>, val currentIndex: Int) : AudioCommand
    data class ReorderContextQueue(val fromIndex: Int, val toIndex: Int) : AudioCommand
    data class AddToUserQueue(val songs: List<QueueSong>, val position: String) : AudioCommand
    data class RemoveFromUserQueue(val indices: List<Int>) : AudioCommand
    data class RemoveSongsById(val songIds: List<String>) : AudioCommand
    data object ClearUserQueue : AudioCommand
    data class PlayAtIndex(val index: Int, val startTime: Double?) : AudioCommand
    data class MarkAsShuffled(val originalSongs: List<QueueSong>) : AudioCommand
    data class PrepareHandoff(val snapshot: JSONObject, val autoplay: Boolean) : AudioCommand
    data object RollbackHandoff : AudioCommand
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
    data class SleepTimerFired(val reason: String, val snapshot: AudioPlaybackSnapshot) : AudioEvent
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
    fun getSleepTimerRemaining(): Double
    fun setRequestId(requestId: String?)
    fun getFullState(): JSONObject?
    fun pauseAndGetFullState(): JSONObject?
    fun executeRemoteControlCommand(command: JSONObject): Boolean
    fun applyRemotePlaybackSnapshot(snapshot: AudioRemotePlaybackSnapshot)
    fun clearRemotePlaybackProjection()
    fun prepareHandoff(
        snapshot: JSONObject,
        autoplay: Boolean,
        completion: (Boolean) -> Unit,
    )
    fun rollbackHandoff()
}
