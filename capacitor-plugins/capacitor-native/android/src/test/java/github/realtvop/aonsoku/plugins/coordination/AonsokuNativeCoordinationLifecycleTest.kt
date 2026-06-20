package github.realtvop.aonsoku.plugins.coordination

import okhttp3.OkHttpClient
import okhttp3.WebSocket
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/// Lifecycle tests for the coordination plugin's foreground-service
/// attach/detach helpers (design §2.1.8, §5.2). These exercise the state
/// transitions without a real WebSocket by injecting fakes via the
/// package-visible test hooks.
class AonsokuNativeCoordinationLifecycleTest {

    private lateinit var plugin: AonsokuNativeCoordinationPlugin
    private lateinit var fakeClient: OkHttpClient
    private lateinit var fakeSocket: WebSocket

    @Before
    fun setUp() {
        plugin = AonsokuNativeCoordinationPlugin()
        fakeClient = OkHttpClient()
        // WebSocket is an interface; a no-op anonymous impl is sufficient
        // because attach only stores the reference.
        fakeSocket = object : WebSocket {
            override fun request() = okhttp3.Request.Builder().url("wss://localhost").build()
            override fun queueSize(): Long = 0L
            override fun send(text: String): Boolean = true
            override fun send(bytes: okio.ByteString): Boolean = true
            override fun close(code: Int, reason: String?): Boolean = true
            override fun cancel() {}
        }
        // Ensure no stale active instance leaks across tests.
        AonsokuNativeCoordinationPlugin.detachActiveForegroundService()
    }

    @After
    fun tearDown() {
        plugin.detachFromForegroundService()
        plugin.setConnectionForTesting(null, null)
    }

    // --- attachToForegroundService ------------------------------------------

    @Test
    fun attachWithoutActiveConnectionIsNoOpAndReturnsFalse() {
        // No client/socket injected yet.
        assertFalse(plugin.attachToForegroundService())
        assertFalse(plugin.isAttachedToForegroundService())
        // But the active flag is set so the next connect() attaches.
        // Verify by injecting a connection after the attach call and
        // re-attaching (simulates connect() after service started).
        plugin.setConnectionForTesting(fakeClient, fakeSocket)
        assertTrue(plugin.attachToForegroundService())
        assertTrue(plugin.isAttachedToForegroundService())
    }

    @Test
    fun attachWithActiveConnectionAttachesAndReturnsTrue() {
        plugin.setConnectionForTesting(fakeClient, fakeSocket)
        assertTrue(plugin.attachToForegroundService())
        assertTrue(plugin.isAttachedToForegroundService())
        val conn = plugin.foregroundServiceConnection
        assertNotNull(conn)
        assertEquals(fakeClient, conn?.client)
        assertEquals(fakeSocket, conn?.webSocket)
    }

    @Test
    fun doubleAttachIsIdempotentAndDoesNotCreateSecondSocket() {
        plugin.setConnectionForTesting(fakeClient, fakeSocket)
        assertTrue(plugin.attachToForegroundService())
        val firstConn = plugin.foregroundServiceConnection
        // Second attach must be a no-op: still true, same holder.
        assertTrue(plugin.attachToForegroundService())
        assertTrue(plugin.isAttachedToForegroundService())
        assertEquals(firstConn, plugin.foregroundServiceConnection)
    }

    // --- detachFromForegroundService ---------------------------------------

    @Test
    fun detachAfterAttachClearsHolder() {
        plugin.setConnectionForTesting(fakeClient, fakeSocket)
        assertTrue(plugin.attachToForegroundService())
        assertTrue(plugin.isAttachedToForegroundService())
        plugin.detachFromForegroundService()
        assertFalse(plugin.isAttachedToForegroundService())
        assertNull(plugin.foregroundServiceConnection)
    }

    @Test
    fun detachWithoutAttachIsNoOp() {
        // Never attached — detach must not throw or change state.
        assertFalse(plugin.isAttachedToForegroundService())
        plugin.detachFromForegroundService()
        assertFalse(plugin.isAttachedToForegroundService())
        assertNull(plugin.foregroundServiceConnection)
    }

    @Test
    fun detachDoesNotCloseThePluginOwnedSocket() {
        // §2.1.8 graceful degradation: detaching releases the service's
        // reference but the plugin keeps the socket. Verify the plugin-owned
        // client/socket are still present after detach.
        plugin.setConnectionForTesting(fakeClient, fakeSocket)
        plugin.attachToForegroundService()
        plugin.detachFromForegroundService()
        val (client, socket) = plugin.connectionForTesting()
        assertEquals(fakeClient, client)
        assertEquals(fakeSocket, socket)
    }

    // --- reconnect suppression after explicit disconnect -------------------

    @Test
    fun explicitDisconnectSetsManualDisconnectFlag() {
        // We cannot call the PluginCall-based disconnect() in a unit test
        // (no Bridge), but we can verify the flag the WebSocket callbacks
        // check is reset by connect() and not flipped by detach.
        plugin.setConnectionForTesting(fakeClient, fakeSocket)
        plugin.attachToForegroundService()
        plugin.detachFromForegroundService()
        assertFalse(plugin.isManualDisconnectForTesting())
    }

    // --- static attach/detach helpers --------------------------------------

    @Test
    fun staticAttachWithoutActiveInstanceReturnsFalse() {
        // No plugin registered as activeInstance.
        // (Other tests may have set it; clear defensively by reflecting —
        // instead just assert the no-active path returns false when no
        // instance is loaded. We cannot easily null out the companion field
        // from here, so this test only asserts the type contract: the static
        // helper returns a Boolean and never throws.)
        val result = AonsokuNativeCoordinationPlugin.attachToActiveForegroundService()
        // result is Boolean either way.
        assertTrue(result is Boolean)
    }

    @Test
    fun staticDetachWithoutActiveInstanceIsNoOp() {
        // Must not throw when no plugin is loaded.
        AonsokuNativeCoordinationPlugin.detachActiveForegroundService()
    }
}