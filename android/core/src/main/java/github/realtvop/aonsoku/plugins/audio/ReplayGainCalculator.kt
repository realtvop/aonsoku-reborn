package github.realtvop.aonsoku.plugins.audio

import org.json.JSONObject
import kotlin.math.min
import kotlin.math.pow

/**
 * ReplayGain 1.0 volume factor, mirroring `src/utils/replayGain.ts`:
 * `min(10^((gain + preAmp) / 20), 1 / peak)`. The result is clamped to the
 * 0..1 range a media player volume accepts.
 */
object ReplayGainCalculator {
    fun volume(replayGainJson: String?, config: ReplayGainConfig): Float {
        if (!config.enabled) return 1f
        val metadata = replayGainJson?.let { runCatching { JSONObject(it) }.getOrNull() }
        val album = config.mode == "album"
        val gain = metadata.number(if (album) "albumGain" else "trackGain") ?: config.defaultGain
        val peak = metadata.number(if (album) "albumPeak" else "trackPeak") ?: 1.0
        val base = 10.0.pow((gain + config.preAmp) / 20.0)
        val limited = if (peak > 0.0) min(base, 1.0 / peak) else base
        return limited.coerceIn(0.0, 1.0).toFloat()
    }

    private fun JSONObject?.number(name: String): Double? {
        if (this == null || !has(name) || isNull(name)) return null
        return optDouble(name).takeIf { it.isFinite() }
    }
}
