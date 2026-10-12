package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.math.pow

class ReplayGainCalculatorTest {
    private val enabled = ReplayGainConfig(enabled = true, mode = "track", preAmp = 0.0, defaultGain = -6.0)

    @Test
    fun leavesVolumeAtUnityWhenDisabled() {
        val json = """{"trackGain":-9.5,"trackPeak":1.0}"""

        assertEquals(1f, ReplayGainCalculator.volume(json, ReplayGainConfig(enabled = false)), 0f)
    }

    @Test
    fun attenuatesByTrackGainAndPreAmp() {
        val json = """{"trackGain":-6.0,"trackPeak":0.9,"albumGain":-3.0,"albumPeak":0.8}"""

        assertEquals(10.0.pow(-6.0 / 20).toFloat(), ReplayGainCalculator.volume(json, enabled), 1e-5f)
        assertEquals(
            10.0.pow(-9.0 / 20).toFloat(),
            ReplayGainCalculator.volume(json, enabled.copy(preAmp = -3.0)),
            1e-5f,
        )
    }

    @Test
    fun usesAlbumValuesInAlbumMode() {
        val json = """{"trackGain":-6.0,"trackPeak":0.9,"albumGain":-3.0,"albumPeak":0.8}"""

        assertEquals(
            10.0.pow(-3.0 / 20).toFloat(),
            ReplayGainCalculator.volume(json, enabled.copy(mode = "album")),
            1e-5f,
        )
    }

    @Test
    fun fallsBackToTheDefaultGainWithoutMetadata() {
        val expected = 10.0.pow(-6.0 / 20).toFloat()

        assertEquals(expected, ReplayGainCalculator.volume(null, enabled), 1e-5f)
        assertEquals(expected, ReplayGainCalculator.volume("not json", enabled), 1e-5f)
        assertEquals(expected, ReplayGainCalculator.volume("""{"albumGain":-1}""", enabled), 1e-5f)
    }

    @Test
    fun neverAmplifiesAndRespectsThePeak() {
        assertEquals(1f, ReplayGainCalculator.volume("""{"trackGain":4.0,"trackPeak":0.5}""", enabled), 0f)
        assertEquals(
            0.5f,
            ReplayGainCalculator.volume("""{"trackGain":-1.0,"trackPeak":2.0}""", enabled),
            1e-5f,
        )
        assertEquals(1f, ReplayGainCalculator.volume("""{"trackGain":0,"trackPeak":0}""", enabled), 0f)
    }
}
