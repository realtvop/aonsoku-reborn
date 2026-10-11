package github.realtvop.aonsoku.plugins.audio

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import org.json.JSONObject
import java.nio.ByteBuffer
import kotlin.math.pow

/** PCM gain stays in PlaybackService, including background/system playback. */
@UnstableApi
class ReplayGainProcessor : BaseAudioProcessor() {
    @Volatile var gain: Float = 1f
    override fun onConfigure(format: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (format.encoding != C.ENCODING_PCM_16BIT) throw AudioProcessor.UnhandledAudioFormatException(format)
        return format
    }
    override fun queueInput(input: ByteBuffer) {
        val output = replaceOutputBuffer(input.remaining())
        while (input.remaining() >= 2) output.putShort((input.short * gain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
        output.flip()
    }
    companion object {
        fun gain(settings: JSONObject, metadata: JSONObject?): Float {
            if (!settings.optBoolean("enabled")) return 1f
            val type = if (settings.optString("type") == "album") "album" else "track"
            val decibels = (metadata?.optDouble("${type}Gain", Double.NaN)?.takeIf(Double::isFinite) ?: settings.optDouble("defaultGain", -6.0)) + settings.optDouble("preAmp", 0.0)
            return 10.0.pow(decibels.coerceIn(-60.0, 30.0) / 20).toFloat()
        }
    }
}
