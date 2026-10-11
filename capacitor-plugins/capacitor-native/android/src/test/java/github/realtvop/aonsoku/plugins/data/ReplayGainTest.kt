package github.realtvop.aonsoku.plugins.data
import github.realtvop.aonsoku.plugins.audio.ReplayGainProcessor
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
class ReplayGainTest {
    @Test fun disabledIsUnity() { assertEquals(1f, ReplayGainProcessor.gain(JSONObject(), JSONObject().put("trackGain", -10)), 0f) }
    @Test fun albumModeAndPreampUseAlbumGain() { assertEquals(1f, ReplayGainProcessor.gain(JSONObject("""{"enabled":true,"type":"album","preAmp":4}"""), JSONObject("""{"trackGain":-20,"albumGain":-4}""")), 0.0001f) }
    @Test fun absentMetadataUsesDefault() { assertEquals(0.501187f, ReplayGainProcessor.gain(JSONObject("""{"enabled":true,"defaultGain":-6}"""), null), 0.0001f) }
}
