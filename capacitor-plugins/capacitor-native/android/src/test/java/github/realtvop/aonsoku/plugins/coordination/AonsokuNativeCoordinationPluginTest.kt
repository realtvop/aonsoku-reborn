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

    // --- buildHelloEnvelope ----------------------------------------------------

    @Test
    fun helloEnvelopeIncludesHandshakeFields() {
        val env = AonsokuNativeCoordinationPlugin.buildHelloEnvelope(
            protocolVersion = 1,
            capabilities = 15,
            deviceId = "dev-1",
            ticket = "ticket-1",
            lastSeq = 42,
        )

        assertEquals(1, env.getInt("version"))
        assertEquals("hello", env.getString("type"))
        assertFalse(env.getString("messageId").isBlank())
        assertEquals(1, env.getInt("protocolVersion"))
        assertEquals(15, env.getInt("capabilities"))
        assertEquals("dev-1", env.getString("deviceId"))
        assertEquals("ticket-1", env.getString("ticket"))
        assertEquals(42L, env.getLong("lastSeq"))
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

    // --- buildCommandAckEnvelope ---------------------------------------------

    @Test
    fun commandAckEnvelopeUsesOriginalMessageIdAndOkResult() {
        val env = AonsokuNativeCoordinationPlugin.buildCommandAckEnvelope(
            protocolVersion = 1,
            messageId = "msg-1",
        )

        assertEquals(1, env.getInt("version"))
        assertEquals("msg-1", env.getString("messageId"))
        assertEquals("command_ack", env.getString("type"))
        assertEquals("ok", env.getJSONObject("result").getString("status"))
    }

    // --- buildRelinquishAckEnvelope ------------------------------------------

    @Test
    fun relinquishAckEnvelopeIncludesTransactionAndSnapshot() {
        val snapshot = JSONObject().put("songId", "song-1")
        val env = AonsokuNativeCoordinationPlugin.buildRelinquishAckEnvelope(
            protocolVersion = 1,
            transactionId = "tx-1",
            snapshot = snapshot,
        )

        assertEquals(1, env.getInt("version"))
        assertEquals("relinquish_ack", env.getString("type"))
        assertFalse(env.getString("messageId").isBlank())
        assertEquals("tx-1", env.getString("transactionId"))
        assertEquals("song-1", env.getJSONObject("snapshot").getString("songId"))
    }

    @Test
    fun handoffFailedEnvelopeIncludesTransactionAndCode() {
        val env = AonsokuNativeCoordinationPlugin.buildHandoffFailedEnvelope(
            protocolVersion = 1,
            transactionId = "tx-1",
            code = "source_pause_timeout",
        )

        assertEquals(1, env.getInt("version"))
        assertEquals("handoff_failed", env.getString("type"))
        assertFalse(env.getString("messageId").isBlank())
        assertEquals("tx-1", env.getString("transactionId"))
        assertEquals("source_pause_timeout", env.getString("code"))
    }

    // --- buildPlaybackSnapshot ------------------------------------------------

    @Test
    fun playbackSnapshotMapsNativeAudioStateToProtocolShape() {
        val audioState = JSONObject(
            """
            {
              "currentSongId": "song-2",
              "currentTime": 42.5,
              "duration": 180,
              "isPlaying": true,
              "contextQueue": {
                "songs": [{"id": "song-1"}, {"id": "song-2"}],
                "currentIndex": 1,
                "sourceId": {"type": "album", "id": "album-1"},
                "sourceName": "Album One"
              },
              "userQueue": [{"id": "song-3"}],
              "isInUserQueue": false,
              "playedUserQueueHistory": [{"id": "song-0"}],
              "isShuffleActive": true,
              "loopState": "all"
            }
            """.trimIndent(),
        )

        val snapshot = AonsokuNativeCoordinationPlugin.buildPlaybackSnapshot(
            sessionId = "session-1",
            audioState = audioState,
            sampledAtSeconds = 123.0,
            volume = 0.75,
        )

        assertNotNull(snapshot)
        snapshot!!
        assertEquals("session-1", snapshot.getString("sessionId"))
        assertEquals("session-1", snapshot.getString("logicalPlaybackSessionId"))
        assertEquals("song-2", snapshot.getString("songId"))
        assertEquals(42.5, snapshot.getDouble("progressSeconds"), 0.001)
        assertEquals(180.0, snapshot.getDouble("durationSeconds"), 0.001)
        assertTrue(snapshot.getBoolean("isPlaying"))
        assertEquals(123.0, snapshot.getDouble("sampledAt"), 0.001)
        assertEquals("song-1", snapshot.getJSONArray("contextQueue").getString(0))
        assertEquals("song-2", snapshot.getJSONArray("contextQueue").getString(1))
        assertEquals(1, snapshot.getInt("contextIndex"))
        assertEquals("album:album-1", snapshot.getString("sourceId"))
        assertEquals("Album One", snapshot.getString("sourceName"))
        assertEquals("song-3", snapshot.getJSONArray("userQueue").getString(0))
        assertEquals("song-0", snapshot.getJSONArray("restorePrevious").getString(0))
        assertTrue(snapshot.getBoolean("shuffle"))
        assertEquals("all", snapshot.getString("repeat"))
        assertEquals(0.75, snapshot.getDouble("volume"), 0.001)
        assertFalse(snapshot.getBoolean("historyWritten"))
        assertFalse(snapshot.getBoolean("nowPlayingSent"))
        assertFalse(snapshot.getBoolean("scrobbleSent"))
    }

    @Test
    fun playbackSnapshotReturnsNullWhenThereIsNoCurrentSong() {
        val snapshot = AonsokuNativeCoordinationPlugin.buildPlaybackSnapshot(
            sessionId = "session-1",
            audioState = JSONObject("""{"isPlaying":false}"""),
            sampledAtSeconds = 123.0,
        )

        assertNull(snapshot)
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
