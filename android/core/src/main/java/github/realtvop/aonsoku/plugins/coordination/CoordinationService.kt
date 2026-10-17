package github.realtvop.aonsoku.plugins.coordination

import org.json.JSONObject

/** Typed coordination port used by playback and native UI services. */
interface CoordinationService {
    fun attachToForegroundService(): Boolean
    fun detachFromForegroundService()
    fun sendCommand(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: JSONObject,
    ): Boolean
    fun publishNativePlaybackSnapshot(): Boolean
}
