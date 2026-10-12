package github.realtvop.aonsoku.plugins.error

/** Stable error codes shared by the native services and their clients. */
object AonsokuNativeError {
    const val CODE_PLAYBACK_FAILED = "playback_failed"
    const val CODE_AUDIO_FOCUS_LOST = "audio_focus_lost"
    const val CODE_AUDIO_SESSION_FAILED = "audio_session_failed"
    const val CODE_NETWORK_UNREACHABLE = "network_unreachable"
    const val CODE_DECODE_ERROR = "decode_error"
    const val CODE_UNKNOWN = "unknown_error"
}
