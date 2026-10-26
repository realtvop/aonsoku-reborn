package github.realtvop.aonsoku.smoke

import android.app.Application
import android.os.Looper
import github.realtvop.aonsoku.BuildConfig
import github.realtvop.aonsoku.data.coordination.CoordinationManager
import github.realtvop.aonsoku.data.coordination.DevicePlayback
import github.realtvop.aonsoku.data.coordination.HandoffPhase
import github.realtvop.aonsoku.player.QueueSource
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.coordination.CoordinationRuntime
import github.realtvop.aonsoku.ui.components.Toast
import github.realtvop.aonsoku.ui.components.ToastKind
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.security.MessageDigest
import java.time.Duration
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Cross-device coordination on the real services and the real socket runtime,
 * against the fake coordination server: registering, staying connected,
 * controlling another device, and taking its playback over.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class CoordinationManagerTest {
    @get:Rule
    val world = SmokeWorld()

    private val coordination get() = world.graph.coordination
    private val server get() = world.coordination
    private val player get() = world.graph.player
    private val state get() = coordination.state.value
    private val toasts = CopyOnWriteArrayList<Toast>()

    @Before
    fun listenToToasts() {
        world.graph.scope.launch { world.graph.toaster.toasts.collect { toasts += it } }
    }

    @Test
    fun registeringConnectsThisDeviceAndListsTheDevices() {
        connect()

        val registration = server.registration!!
        assertEquals(world.server.url, registration.getString("identityUrl"))
        assertEquals(SmokeWorld.USERNAME, registration.getString("username"))
        // The stored Subsonic token with its fixed salt proves the account.
        assertEquals("token", registration.getString("authMode"))
        assertEquals(md5(SmokeWorld.PASSWORD + SubsonicAuthBuilder.SALT), registration.getString("token"))
        assertEquals(SubsonicAuthBuilder.SALT, registration.getString("salt"))
        assertEquals("Test Phone", registration.getString("deviceName"))
        assertEquals(CoordinationManager.PLATFORM, registration.getString("platform"))
        assertEquals(BuildConfig.APP_VERSION, registration.getString("clientVersion"))
        assertEquals(15, registration.getInt("capabilities"))

        val hello = server.receivedOfType("hello").single()
        assertEquals(FakeCoordinationServer.SELF_ID, hello.getString("deviceId"))
        assertEquals(15, hello.getInt("capabilities"))
        assertEquals(1, hello.getInt("protocolVersion"))

        world.waitUntil("the device list") { state.devices.map { it.name } == listOf("Test Phone") }
        assertTrue(state.lastSyncAt != null)
        // Asked for what the others play right away.
        world.waitUntil("a request for snapshots") { server.receivedOfType("request_snapshots").isNotEmpty() }
        // Kept for the next start.
        val runtime = CoordinationRuntime.getInstance(world.graph.application)
        assertEquals(FakeCoordinationServer.SELF_ID, runtime.loadTokens()?.deviceId)
        assertEquals(server.url to world.server.url, runtime.loadConfig())
    }

    @Test
    fun aDroppedSocketIsOpenedAgainWithAFreshTicket() {
        connect()

        server.dropSocket()

        world.waitUntil("a second socket") { server.socketsOpened.get() == 2 && state.isConnected }
        assertEquals(2, server.requests.count { it == "POST /v1/auth/ws-ticket" })
        world.waitUntil("a second hello") { server.receivedOfType("hello").size == 2 }
    }

    @Test
    fun theAccessTokenIsRefreshedAndAnUnknownRefreshTokenRecovered() {
        server.expiresIn = 30
        connect()
        // The token expires within a minute, so it was refreshed before the ticket.
        val beforeTicket = server.requests.takeWhile { it != "POST /v1/auth/ws-ticket" }
        assertTrue(server.requests.toString(), "POST /v1/auth/token" in beforeTicket)

        // The server no longer knows the refresh token: the account is proven again.
        server.refreshFailure = "authentication_failed"
        server.requests.clear()
        server.dropSocket()
        world.waitUntil("the socket to open again") { server.socketsOpened.get() == 2 && state.isConnected }
        val recovery = server.requests.takeWhile { it != "POST /v1/auth/ws-ticket" }
        assertEquals(
            listOf("POST /v1/auth/token", "POST /v1/auth/challenge", "POST /v1/auth/token"),
            recovery.takeLast(3),
        )
        assertTrue(state.isRegistered)
    }

    @Test
    fun aRevokedDeviceIsForgotten() {
        server.expiresIn = 30
        connect()

        server.refreshFailure = "device_revoked"
        server.dropSocket()

        world.waitUntil("the device to be forgotten") { !state.isRegistered }
        assertEquals(DevicePlayback.handoffError(world.graph.strings(), "device_revoked"), state.error)
        val runtime = CoordinationRuntime.getInstance(world.graph.application)
        assertNull(runtime.loadTokens())
        // The server stays configured for connecting again.
        assertEquals(server.url, state.serverUrl)
    }

    @Test
    fun anotherDeviceIsControlledFromHere() {
        connect()
        // This device plays something of its own, which pauses.
        world.waitUntil("the library") { world.await { world.graph.library.localSong("so-al-2-1") } != null }
        val paperBoats = world.await { world.graph.library.albumSongs("al-2") }
        player.playSongs(paperBoats, 0, source = QueueSource.album("al-2"))
        world.waitUntil("local playback") { player.local.value.current?.id == "so-al-2-1" }
        val desk = addDesk(snapshot("so-al-1-2"))

        assertTrue(desk.canBeControlled)
        coordination.enterRemoteControl("device-desk")

        world.waitUntil("the control session") {
            server.receivedOfType("control_session_begin").singleOrNull()
                ?.getString("targetDeviceId") == "device-desk"
        }
        world.waitUntil("the desk's song") { player.state.value.current?.title == "Polar Night" }
        val shown = player.state.value
        assertEquals("Desk", shown.remoteDevice)
        assertEquals(listOf("First Snow", "Polar Night", "Green Sky", "Thaw"), shown.contextSongs.map { it.title })
        assertEquals(1, shown.contextIndex)
        assertTrue(shown.isPlaying)
        assertEquals("so-al-2-1", player.local.value.current?.id)
        world.waitUntil("this device to pause") { !player.local.value.isPlaying }
        assertTrue(toasts.any { it.message == "Remote controlling: Desk" })

        player.next()
        player.seek(30.0)
        player.toggleCurrentLike()
        player.setVolume(0.8)
        player.cycleRepeat()
        player.toggleShuffle()
        world.waitUntil("the commands") { commands().size == 6 }
        assertEquals(
            listOf(
                JSONObject().put("type", "next"),
                JSONObject().put("type", "seek").put("seconds", 30.0),
                JSONObject().put("type", "toggle_like"),
                JSONObject().put("type", "set_volume").put("volume", 0.8),
                JSONObject().put("type", "set_repeat").put("mode", "all"),
                JSONObject().put("type", "set_shuffle").put("enabled", true),
            ).map { it.toString() },
            commands().map { it.toString() },
        )
        val command = server.receivedOfType("command").first()
        assertEquals("device-desk", command.getString("targetDeviceId"))
        assertEquals(1, command.getInt("expectedGeneration"))
        assertTrue(player.state.value.isCurrentStarred)

        // An album starts on the desk; the queue of this device is not touched.
        val tidal = world.await { world.graph.library.albumSongs("al-3") }
        player.playSongs(tidal, 1, source = QueueSource.album("al-3"))
        world.waitUntil("the album command") { commands().size == 7 }
        assertEquals(
            JSONObject().put("type", "play_album").put("album_id", "al-3").put("index", 1)
                .put("shuffle", false).toString(),
            commands().last().toString(),
        )
        assertEquals("so-al-2-1", player.local.value.current?.id)

        coordination.exitRemoteControl()
        world.waitUntil("the end of the session") { server.receivedOfType("control_session_end").isNotEmpty() }
        assertNull(player.state.value.remoteDevice)
        assertEquals("so-al-2-1", player.state.value.current?.id)
        assertTrue(toasts.any { it.message == "Exited remote control" })
    }

    @Test
    fun replacingTheQueueOfAControlledDeviceAsksFirst() {
        connect()
        addDesk(snapshot("so-al-1-1", userQueue = listOf("so-al-5-1")))
        coordination.enterRemoteControl("device-desk")
        world.waitUntil("the desk's queue") { player.state.value.userQueue.size == 1 }

        val songs = world.await { world.graph.library.albumSongs("al-2") }
        player.playSongs(songs, 0)
        val request = player.pendingReplacement.value!!
        assertEquals("device-desk", request.targetDeviceId)
        // Play after this song instead: nothing is cleared there.
        player.confirmReplacement(replaceQueue = false)
        world.waitUntil("the command") { commands().isNotEmpty() }
        assertEquals(
            JSONObject().put("type", "add_to_queue_next")
                .put("song_ids", org.json.JSONArray(listOf("so-al-2-1", "so-al-2-2", "so-al-2-3")))
                .toString(),
            commands().single().toString(),
        )

        // A question asked about the desk goes when control ends.
        player.playSongs(songs, 0)
        assertEquals("device-desk", player.pendingReplacement.value?.targetDeviceId)
        coordination.exitRemoteControl()
        assertNull(player.pendingReplacement.value)
    }

    @Test
    fun remoteControlEndsWhenTheDeviceGoesOffline() {
        connect()
        addDesk(snapshot("so-al-1-2"))
        coordination.enterRemoteControl("device-desk")
        world.waitUntil("remote control") { player.state.value.remoteDevice == "Desk" }

        server.projection("device-desk", snapshot("so-al-1-2"), isOnline = false, revision = 2)

        world.waitUntil("the end of remote control") { player.state.value.remoteDevice == null }
        assertNull(state.controlledDeviceId)
        assertTrue(toasts.any { it.message == "The device went offline." })
    }

    @Test
    fun playbackOfAnotherDeviceContinuesHere() {
        connect()
        world.waitUntil("the library") { world.await { world.graph.library.localSong("so-al-1-2") } != null }
        addDesk(snapshot("so-al-1-2", progress = 42.0))

        coordination.requestHandoff("device-desk")

        world.waitUntil("the handoff request") { server.receivedOfType("handoff_candidate_request").isNotEmpty() }
        val request = server.receivedOfType("handoff_candidate_request").single()
        assertEquals("device-desk", request.getString("sourceDeviceId"))
        assertEquals(1, request.getInt("expectedGeneration"))
        assertEquals(1, request.getInt("expectedSnapshotRevision"))
        assertEquals(HandoffPhase.Prepare, coordination.handoff.value.phase)
        assertTrue(toasts.any { it.message == "Preparing handoff..." })

        // The server hands over the desk's queue; it is prepared here, paused.
        val handed = snapshot("so-al-1-2", progress = 42.0, playing = false)
        server.send(
            "handoff_candidate",
            JSONObject()
                .put("transactionId", "tx-1")
                .put("sourceDeviceId", "device-desk")
                .put("sessionId", "session-desk")
                .put("generation", 1)
                .put("snapshotRevision", 1)
                .put("snapshot", handed),
        )
        world.waitUntil("this device to be ready") { server.receivedOfType("target_ready").isNotEmpty() }
        assertEquals("tx-1", server.receivedOfType("target_ready").single().getString("transactionId"))
        assertEquals("so-al-1-2", player.local.value.current?.id)

        server.send(
            "handoff_committed",
            JSONObject()
                .put("transactionId", "tx-1")
                .put("newGeneration", 2)
                .put("snapshot", handed),
        )
        world.waitUntil("the handoff to finish") { coordination.handoff.value.phase == HandoffPhase.Committed }
        assertTrue(toasts.any { it.message == "Handoff successful!" })
        assertEquals(
            listOf("First Snow", "Polar Night", "Green Sky", "Thaw"),
            player.local.value.contextSongs.map { it.title },
        )
        assertEquals("so-al-1-2", player.state.value.current?.id)
    }

    @Test
    fun aHandoffTheSourceNeverSettlesGivesUp() {
        connect()
        addDesk(snapshot("so-al-1-2"))

        coordination.requestHandoff("device-desk")
        world.waitUntil("the handoff request") { server.receivedOfType("handoff_candidate_request").isNotEmpty() }

        // The source never answers.
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(16))
        world.waitUntil("the handoff to fail") { coordination.handoff.value.error != null }
        assertEquals("The source device did not confirm pause in time.", coordination.handoff.value.error)
        assertNull(coordination.handoff.value.phase)
    }

    @Test
    fun serverErrorsDuringAHandoffEndIt() {
        connect()
        addDesk(snapshot("so-al-1-2"))
        coordination.requestHandoff("device-desk")
        world.waitUntil("the handoff request") { server.receivedOfType("handoff_candidate_request").isNotEmpty() }

        server.send("error", JSONObject().put("code", "handoff_conflict").put("reason", "taken"))

        world.waitUntil("the handoff to fail") { coordination.handoff.value.error != null }
        assertEquals("Another handoff already took this session.", coordination.handoff.value.error)
        assertTrue(toasts.any { it.kind == ToastKind.Error && it.message == "Another handoff already took this session." })
        // Errors outside a handoff are kept for the settings page.
        server.send("error", JSONObject().put("code", "rate_limited").put("reason", "slow down"))
        world.waitUntil("the error") { state.error == "rate_limited: slow down" }
    }

    @Test
    fun aSessionTakenOverElsewhereIsAnnounced() {
        connect()
        server.addDevice("device-desk", "Desk")
        server.devicesChanged()
        world.waitUntil("the desk") { state.devices.any { it.id == "device-desk" } }

        server.send(
            "session_superseded",
            JSONObject().put("supersededGeneration", 1).put("transferredToDevice", "device-desk"),
        )

        world.waitUntil("the announcement") {
            toasts.any { it.message == "This session has been taken over by Desk, playback paused." }
        }
    }

    @Test
    fun devicesAreRenamedAndRevoked() {
        connect()
        server.addDevice("device-desk", "Desk")
        server.devicesChanged()
        world.waitUntil("the desk") { state.devices.size == 2 }

        world.await { coordination.renameDevice(FakeCoordinationServer.SELF_ID, " Pocket ") }
        assertEquals(listOf("Pocket", "Desk"), state.devices.map { it.name })

        world.await { coordination.revokeDevice("device-desk") }
        assertEquals(listOf("Pocket"), state.devices.map { it.name })
        assertTrue("DELETE /v1/devices/device-desk" in server.requests)
    }

    @Test
    fun disconnectingRevokesAndForgetsThisDevice() {
        connect()

        world.await { coordination.disconnectThisDevice() }

        assertTrue("DELETE /v1/devices/${FakeCoordinationServer.SELF_ID}" in server.requests)
        assertFalse(state.isRegistered)
        assertTrue(state.devices.isEmpty())
        assertEquals(server.url, state.serverUrl)
        world.waitUntil("the socket to close") { !server.isSocketOpen }
        val runtime = CoordinationRuntime.getInstance(world.graph.application)
        assertNull(runtime.loadTokens())
    }

    @Test
    fun deletingTheAccountForgetsThisDevice() {
        connect()

        world.await { coordination.deleteAccount() }

        assertTrue("DELETE /v1/account" in server.requests)
        assertFalse(state.isRegistered)
    }

    @Test
    fun anotherMusicAccountCannotReuseThePreviousRegistration() {
        connect()
        world.await { world.graph.signOut() }
        world.graph.application.getSharedPreferences("coordination_account_owner", 0)
            .edit().putString("owner", "another-server\u001fanother-user").commit()
        world.signIn()
        world.waitUntil("the session to start") { world.graph.session.credentials != null }
        assertFalse(state.isRegistered)
        assertEquals(null, github.realtvop.aonsoku.plugins.coordination.CoordinationRuntime.getInstance(world.graph.application).loadTokens())
    }

    @Test
    fun aRegisteredDeviceConnectsAgainAtTheNextSession() {
        connect()
        world.await { world.graph.signOut() }
        world.waitUntil("the socket to close") { !server.isSocketOpen }
        assertFalse(state.isRegistered)

        world.signIn()

        world.waitUntil("the socket to open again") { server.socketsOpened.get() == 2 && state.isConnected }
        assertEquals(FakeCoordinationServer.SELF_ID, state.deviceId)
    }

    private fun connect() {
        world.signIn()
        world.await { coordination.connect(server.url, world.server.url, "Test Phone") }
        world.waitUntil("the connection") { state.isConnected && server.receivedOfType("hello").isNotEmpty() }
        world.waitUntil("the welcome") { state.devices.isNotEmpty() }
    }

    /** Adds a device named Desk that plays [snapshot]. */
    private fun addDesk(snapshot: JSONObject) = run {
        server.addDevice("device-desk", "Desk")
        server.devicesChanged()
        server.projection("device-desk", snapshot)
        world.waitUntil("the desk's snapshot") { "device-desk" in state.snapshots && state.devices.size == 2 }
        DevicePlayback.group(
            devices = state.devices,
            snapshots = state.snapshots,
            currentDeviceId = state.deviceId,
            controlledDeviceId = state.controlledDeviceId,
            thisDeviceName = "This Device",
            now = System.currentTimeMillis(),
            nowElapsed = android.os.SystemClock.elapsedRealtime(),
        ).live.single()
    }

    /** What the desk plays: a song of Northern Lights. */
    private fun snapshot(
        songId: String,
        progress: Double = 12.0,
        playing: Boolean = true,
        userQueue: List<String> = emptyList(),
    ) = FakeCoordinationServer.snapshot(
        songId = songId,
        context = listOf("so-al-1-1", "so-al-1-2", "so-al-1-3", "so-al-1-4"),
        progress = progress,
        playing = playing,
        userQueue = userQueue,
    )

    private fun commands(): List<JSONObject> =
        server.receivedOfType("command").map { it.getJSONObject("command") }

    private fun md5(text: String): String = MessageDigest.getInstance("MD5")
        .digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }
}
