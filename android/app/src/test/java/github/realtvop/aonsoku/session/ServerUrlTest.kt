package github.realtvop.aonsoku.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerUrlTest {
    @Test
    fun normalizesWhitespaceAndTrailingSlashes() {
        assertEquals(
            "https://music.example/base",
            SessionManager.normalizeServerUrl("  https://music.example/base// "),
        )
    }

    @Test
    fun acceptsOnlyHttpUrlsWithAHost() {
        assertTrue(SessionManager.isValidServerUrl("https://music.example"))
        assertTrue(SessionManager.isValidServerUrl("http://192.168.1.10:4533/navidrome"))
        assertFalse(SessionManager.isValidServerUrl("https://"))
        assertFalse(SessionManager.isValidServerUrl("music.example"))
        assertFalse(SessionManager.isValidServerUrl("ftp://music.example"))
        assertFalse(SessionManager.isValidServerUrl("https://bad host"))
        assertFalse(SessionManager.isValidServerUrl(""))
    }
}
