package github.realtvop.aonsoku.plugins.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubsonicAuthBuilderTest {
    @Test
    fun generateTokenUsesAonsokuSalt() {
        assertEquals(
            "8dcfd84619d18f19ce00d449bc1f9611",
            SubsonicAuthBuilder.generateToken("secret"),
        )
    }

    @Test
    fun encodePasswordUsesSubsonicEncodedPasswordFormat() {
        assertEquals(
            "enc:736563726574",
            SubsonicAuthBuilder.encodePassword("secret"),
        )
    }

    @Test
    fun buildQueryParamsUsesTokenFieldsForTokenAuth() {
        val params = SubsonicAuthBuilder.buildQueryParams(
            username = "alice",
            password = "token-value",
            authType = "token",
            protocolVersion = "1.16.1",
        )

        assertEquals("alice", params["u"])
        assertEquals("1.16.1", params["v"])
        assertEquals("Aonsoku", params["c"])
        assertEquals("json", params["f"])
        assertEquals("token-value", params["t"])
        assertEquals(SubsonicAuthBuilder.SALT, params["s"])
        assertFalse(params.containsKey("p"))
    }

    @Test
    fun buildQueryParamsUsesPasswordFieldForPasswordAuth() {
        val params = SubsonicAuthBuilder.buildQueryParams(
            username = "alice",
            password = "enc:736563726574",
            authType = "password",
        )

        assertEquals("enc:736563726574", params["p"])
        assertFalse(params.containsKey("t"))
        assertFalse(params.containsKey("s"))
    }

    @Test
    fun parseVersionNumberMatchesIosBridgeContract() {
        assertEquals(11602, SubsonicAuthBuilder.parseVersionNumber("1.16.2"))
        assertEquals(0, SubsonicAuthBuilder.parseVersionNumber("1"))
        assertTrue(SubsonicAuthBuilder.parseVersionNumber("2.0.0") > 11600)
    }
}
