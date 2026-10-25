package github.realtvop.aonsoku.data.coordination

import android.os.SystemClock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.json.JSONArray
import org.json.JSONObject

// The wire types of the coordination protocol, version 1, as the web app
// declares them in `src/coordination/types.ts`.

internal val CoordinationJson = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    explicitNulls = false
    encodeDefaults = true
}

/** Everything this app takes part in: history, observing, control, and handoff. */
const val COORDINATION_CAPABILITIES = 1 or 2 or 4 or 8

const val COORDINATION_PROTOCOL_VERSION = 1

/** A device registered on the coordination account. */
@Serializable
data class DeviceDto(
    val id: String,
    val name: String = "",
    val platform: String = "",
    val clientVersion: String? = null,
    val capabilities: Int = 0,
    val createdAt: String = "",
    val lastOnlineAt: String? = null,
    val revokedAt: String? = null,
    val isControlling: Boolean = false,
)

/** What a device is playing, as it publishes it. Times are in seconds. */
@Serializable
data class PlaybackSnapshot(
    val sessionId: String = "",
    val mediaKind: String = "song",
    val songId: String = "",
    val progressSeconds: Double = 0.0,
    val durationSeconds: Double = 0.0,
    val isPlaying: Boolean = false,
    val sampledAt: Double = 0.0,
    val contextQueue: List<String> = emptyList(),
    val contextIndex: Int? = null,
    val sourceId: String? = null,
    val sourceName: String? = null,
    val userQueue: List<String> = emptyList(),
    val inUserQueue: Boolean = false,
    val restorePrevious: List<String> = emptyList(),
    val shuffle: Boolean = false,
    val repeat: String = "off",
    val volume: Double? = null,
) {
    /** A song that another device can take over or be controlled through. */
    val hasSong: Boolean get() = songId.isNotEmpty()
}

/**
 * The latest snapshot of a device and when it was taken, so its progress can
 * be carried forward while it plays.
 */
data class DeviceSnapshot(
    val snapshot: PlaybackSnapshot,
    val isOnline: Boolean,
    val generation: Int,
    val snapshotRevision: Int,
    /** Wall-clock time it arrived here. */
    val receivedAt: Long,
    /** How long the server had held it when it was sent, in seconds. */
    val ageSeconds: Double,
    /** `SystemClock.elapsedRealtime()` when it arrived. */
    val receivedAtElapsed: Long,
) {
    /** Where playback is now, assuming it went on since the snapshot was taken. */
    fun progressAt(nowElapsed: Long): Double {
        val duration = snapshot.durationSeconds.finiteOrZero()
        val progress = snapshot.progressSeconds.finiteOrZero()
        if (!snapshot.isPlaying) return progress.coerceAtMost(duration)
        val elapsed = (nowElapsed - receivedAtElapsed).coerceAtLeast(0) / 1000.0
        return (progress + ageSeconds.finiteOrZero() + elapsed).coerceAtMost(duration)
    }

    /**
     * The same playback anchored at this moment, with what the user just asked
     * for; the device's next snapshot replaces it.
     */
    fun carriedTo(
        position: Double? = null,
        isPlaying: Boolean = snapshot.isPlaying,
        nowElapsed: Long = SystemClock.elapsedRealtime(),
    ): DeviceSnapshot = copy(
        snapshot = snapshot.copy(
            progressSeconds = position ?: progressAt(nowElapsed),
            isPlaying = isPlaying,
        ),
        ageSeconds = 0.0,
        receivedAtElapsed = nowElapsed,
    )

    private fun Double.finiteOrZero(): Double = if (isFinite() && this > 0) this else 0.0
}

/** State of the realtime connection, as the native runtime reports it. */
enum class CoordinationConnection(val key: String) {
    Disconnected("disconnected"),
    Connecting("connecting"),
    Connected("connected"),
    Reconnecting("reconnecting"),
    Error("error"),
    ;

    companion object {
        fun fromValue(value: String): CoordinationConnection =
            entries.firstOrNull { it.key == value } ?: Disconnected
    }
}

/** A command for the device under remote control. */
sealed interface RemoteCommand {
    val type: String

    data object Play : RemoteCommand {
        override val type = "play"
    }

    data object Pause : RemoteCommand {
        override val type = "pause"
    }

    data object TogglePlayPause : RemoteCommand {
        override val type = "toggle_play_pause"
    }

    data object Previous : RemoteCommand {
        override val type = "previous"
    }

    data object Next : RemoteCommand {
        override val type = "next"
    }

    data class Seek(val seconds: Double) : RemoteCommand {
        override val type = "seek"
    }

    /** [volume] from 0 to 1. */
    data class SetVolume(val volume: Double) : RemoteCommand {
        override val type = "set_volume"
    }

    data class SetShuffle(val enabled: Boolean) : RemoteCommand {
        override val type = "set_shuffle"
    }

    /** [mode] is "off", "one", or "all". */
    data class SetRepeat(val mode: String) : RemoteCommand {
        override val type = "set_repeat"
    }

    data object ToggleLike : RemoteCommand {
        override val type = "toggle_like"
    }

    data class PlaySong(val songId: String) : RemoteCommand {
        override val type = "play_song"
    }

    data class PlayAlbum(val albumId: String, val index: Int, val shuffle: Boolean) : RemoteCommand {
        override val type = "play_album"
    }

    data class PlayPlaylist(val playlistId: String, val index: Int, val shuffle: Boolean) : RemoteCommand {
        override val type = "play_playlist"
    }

    data class AddToQueueNext(val songIds: List<String>) : RemoteCommand {
        override val type = "add_to_queue_next"
    }

    data class AddToQueueLast(val songIds: List<String>) : RemoteCommand {
        override val type = "add_to_queue_last"
    }

    data object ClearQueue : RemoteCommand {
        override val type = "clear_queue"
    }

    data class PlayAtIndex(val songIds: List<String>, val index: Int) : RemoteCommand {
        override val type = "play_at_index"
    }

    /** The command as the runtime sends it. */
    fun toJson(): JSONObject {
        val json = JSONObject().put("type", type)
        when (this) {
            is Seek -> json.put("seconds", seconds)
            is SetVolume -> json.put("volume", volume)
            is SetShuffle -> json.put("enabled", enabled)
            is SetRepeat -> json.put("mode", mode)
            is PlaySong -> json.put("song_id", songId)
            is PlayAlbum -> json.put("album_id", albumId).put("index", index).put("shuffle", shuffle)
            is PlayPlaylist -> json.put("playlist_id", playlistId).put("index", index).put("shuffle", shuffle)
            is AddToQueueNext -> json.put("song_ids", JSONArray(songIds))
            is AddToQueueLast -> json.put("song_ids", JSONArray(songIds))
            is PlayAtIndex -> json.put("song_ids", JSONArray(songIds)).put("index", index)
            else -> Unit
        }
        return json
    }
}

// HTTP bodies of `/v1/auth`.

@Serializable
internal data class ChallengeRequest(val identityUrl: String, val username: String)

@Serializable
internal data class ChallengeResponse(val challengeId: String)

@Serializable
internal data class RegisterRequest(
    val challengeId: String,
    val identityUrl: String,
    val username: String,
    val authMode: String,
    val token: String? = null,
    val salt: String? = null,
    val password: String? = null,
    val deviceName: String,
    val platform: String,
    val clientVersion: String? = null,
    val capabilities: Int? = null,
)

@Serializable
internal data class RegisterResponse(
    val deviceId: String,
    val accountId: String,
    val accessToken: String,
    val refreshToken: String,
    val expiresIn: Long,
    val historyLimit: Int = 0,
)

@Serializable
internal data class TokenRefreshRequest(
    val deviceId: String,
    val refreshToken: String,
    val challengeId: String? = null,
    val identityUrl: String? = null,
    val username: String? = null,
    val authMode: String? = null,
    val token: String? = null,
    val salt: String? = null,
    val password: String? = null,
)

@Serializable
internal data class TokenRefreshResponse(
    val accessToken: String,
    val refreshToken: String,
    val expiresIn: Long,
)

@Serializable
internal data class WsTicketResponse(val ticket: String)

@Serializable
internal data class RenameDeviceRequest(val name: String)

@Serializable
internal data class ErrorBody(val code: String? = null, val reason: String? = null)
