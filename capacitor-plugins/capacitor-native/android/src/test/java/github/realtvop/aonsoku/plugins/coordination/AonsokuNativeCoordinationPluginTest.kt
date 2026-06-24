package github.realtvop.aonsoku.plugins.coordination

import okhttp3.OkHttpClient
import okhttp3.WebSocket
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pure-function tests for the coordination plugin's envelope builders and
/// URL helpers. These do not touch the Android Keystore or WebSocket stack,
/// so they run as plain JUnit tests.
class AonsokuNativeCoordinationPluginTest {

    // --- buildHeartbeatEnvelope ------------------------------------------------

    @Test
    fun heartbeatEnvelopeHasProtocolVersionTypeAndMessageId() {
        val env = AonsokuNativeCoordinationPlugin.buildHeartbeatEnvelope(protocolVersion = 1)
        assertEquals(1, env.getInt("version"))
        assertEquals("heartbeat", env.getString("type"))
        assertFalse(env.getString("messageId").isBlank())
    }

    @Test
    fun heartbeatEnvelopeUsesGivenProtocolVersion() {
        val env = AonsokuNativeCoordinationPlugin.buildHeartbeatEnvelope(protocolVersion = 2)
        assertEquals(2, env.getInt("version"))
    }

    @Test
    fun heartbeatEnvelopeMessageIdIsUniquePerCall() {
        val a = AonsokuNativeCoordinationPlugin.buildHeartbeatEnvelope(1).getString("messageId")
        val b = AonsokuNativeCoordinationPlugin.buildHeartbeatEnvelope(1).getString("messageId")
        assertNotEqualsUuid(a, b)
    }

    // --- buildTargetReadyEnvelope ---------------------------------------------

    @Test
    fun targetReadyEnvelopeIncludesSourceDeviceAndSession() {
        val env = AonsokuNativeCoordinationPlugin.buildTargetReadyEnvelope(
            protocolVersion = 1,
            transactionId = "tx-1",
            generation = 2,
            snapshotRevision = 3,
            sourceDeviceId = "dev-2",
            sessionId = "sess-1",
        )

        assertEquals(1, env.getInt("version"))
        assertEquals("target_ready", env.getString("type"))
        assertFalse(env.getString("messageId").isBlank())
        assertEquals("tx-1", env.getString("transactionId"))
        assertEquals(2, env.getInt("generation"))
        assertEquals(3, env.getInt("snapshotRevision"))
        assertEquals("dev-2", env.getString("sourceDeviceId"))
        assertEquals("sess-1", env.getString("sessionId"))
    }

    // --- parseJsonObject -------------------------------------------------------

    @Test
    fun parseJsonObjectReturnsObjectForValidJson() {
        val parsed = AonsokuNativeCoordinationPlugin.parseJsonObject("""{"a":1}""")
        assertNotNull(parsed)
        assertEquals(1, parsed!!.getInt("a"))
    }

    @Test
    fun parseJsonObjectReturnsNullForMalformedJson() {
        assertNull(AonsokuNativeCoordinationPlugin.parseJsonObject("not json"))
    }

    @Test
    fun parseJsonObjectReturnsNullForArrayJson() {
        // An array is valid JSON but not a JSONObject; callers expect null
        // rather than a ClassCastException when wrapping into an envelope.
        assertNull(AonsokuNativeCoordinationPlugin.parseJsonObject("[1,2,3]"))
    }

    @Test
    fun parseJsonObjectReturnsNullForEmptyString() {
        assertNull(AonsokuNativeCoordinationPlugin.parseJsonObject(""))
    }

    // --- buildTicketUrl --------------------------------------------------------

    @Test
    fun buildTicketUrlAppendsTicketAsQueryParameter() {
        val url = AonsokuNativeCoordinationPlugin.buildTicketUrl("wss://h/v1/realtime", "abc")
        assertEquals("wss://h/v1/realtime?ticket=abc", url)
    }

    @Test
    fun buildTicketUrlPreservesExistingQueryString() {
        val url = AonsokuNativeCoordinationPlugin.buildTicketUrl("wss://h/v1/realtime?proto=1", "abc")
        assertEquals("wss://h/v1/realtime?proto=1&ticket=abc", url)
    }

    @Test
    fun buildTicketUrlEncodesSpecialCharacters() {
        // Tickets that contain &/=? would otherwise break the URL.
        val url = AonsokuNativeCoordinationPlugin.buildTicketUrl("wss://h/v1/realtime", "a&b=c?d/e#f")
        assertTrue("ticket should be encoded: $url", url.endsWith("ticket=a%26b%3Dc%3Fd%2Fe%23f"))
        // The encoded form must not introduce an extra query boundary.
        assertFalse(url.contains("ticket=a&b"))
    }

    // --- CoordinationTokenStore constants -------------------------------------

    @Test
    fun coordinationTokenStoreSharesPrefsNameWithPlugin() {
        // The plugin stores config in the same prefs file as the token store's
        // ciphertext blob. If these drift apart, clearTokens/config isolation
        // breaks. Lock the shared name to catch regressions.
        assertEquals(
            AonsokuNativeCoordinationPlugin.PREFS_NAME,
            CoordinationTokenStore.PREFS_NAME,
        )
    }

    private fun assertNotEqualsUuid(a: String, b: String) {
        assertTrue("messageId should be unique: $a == $b", a != b)
    }
}
