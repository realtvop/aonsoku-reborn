package github.realtvop.aonsoku.data.coordination

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DevicePlaybackTest {
    private val now = 1_000_000_000L

    @Test
    fun devicesAreSortedIntoTheSectionsOfThePanel() {
        val groups = group(
            devices = listOf(
                device("self"),
                device("live"),
                device("paused-live"),
                device("offline"),
                device("stale"),
                device("idle"),
                device("controller", controlling = true),
            ),
            snapshots = mapOf(
                "live" to entry(playing = true),
                "paused-live" to entry(playing = false),
                "offline" to entry(online = false, receivedAt = now - 60_000),
                "stale" to entry(online = false, receivedAt = now - DevicePlayback.OFFLINE_EXPIRY_MS),
                "idle" to entry(songId = ""),
                "controller" to entry(),
            ),
            currentDeviceId = "self",
        )

        assertEquals("self", groups.thisDevice?.device?.id)
        assertEquals(listOf("live", "paused-live"), groups.live.map { it.device.id })
        assertEquals(listOf("offline"), groups.offline.map { it.device.id })
        assertEquals(listOf("stale", "idle", "controller"), groups.hidden.map { it.device.id })
        assertEquals(listOf("live", "paused-live", "offline"), groups.others.map { it.device.id })
    }

    @Test
    fun onlyOnlineDevicesCanBeControlledButRecentOfflineOnesContinued() {
        val groups = group(
            devices = listOf(device("live"), device("offline")),
            snapshots = mapOf(
                "live" to entry(),
                "offline" to entry(online = false, receivedAt = now - 1_000),
            ),
            currentDeviceId = "self",
        )

        val live = groups.live.single()
        assertTrue(live.canBeControlled)
        assertTrue(live.canBeContinuedLocally)
        val offline = groups.offline.single()
        assertFalse(offline.canBeControlled)
        assertTrue(offline.canBeContinuedLocally)
    }

    @Test
    fun theControlledDeviceCannotBeControlledAgain() {
        val groups = group(
            devices = listOf(device("live")),
            snapshots = mapOf("live" to entry()),
            currentDeviceId = "self",
            controlledDeviceId = "live",
        )

        assertFalse(groups.live.single().canBeControlled)
        assertTrue(groups.live.single().canBeContinuedLocally)
    }

    @Test
    fun thisDeviceIsListedBeforeTheServerListsIt() {
        val unregistered = group(devices = emptyList(), snapshots = emptyMap(), currentDeviceId = null)
        assertEquals(DevicePlayback.LOCAL_DEVICE_ID, unregistered.thisDevice?.device?.id)
        assertEquals("This Device", unregistered.thisDevice?.device?.name)

        val registered = group(devices = listOf(device("other")), snapshots = emptyMap(), currentDeviceId = "self")
        assertEquals("self", registered.thisDevice?.device?.id)
        // A device without a song is not offered.
        assertEquals(listOf("other"), registered.hidden.map { it.device.id })
    }

    @Test
    fun progressGoesOnWhilePlayingAndStopsAtTheEnd() {
        val playing = entry(playing = true, progress = 10.0, ageSeconds = 2.0, receivedAtElapsed = 5_000)
        assertEquals(12.0, playing.progressAt(5_000), 0.001)
        assertEquals(15.0, playing.progressAt(8_000), 0.001)
        assertEquals(200.0, playing.progressAt(1_000_000), 0.001)

        val paused = entry(playing = false, progress = 10.0, ageSeconds = 2.0, receivedAtElapsed = 5_000)
        assertEquals(10.0, paused.progressAt(8_000), 0.001)

        val carried = playing.carriedTo(position = 40.0, isPlaying = false, nowElapsed = 9_000)
        assertEquals(40.0, carried.progressAt(20_000), 0.001)
    }

    private fun group(
        devices: List<DeviceDto>,
        snapshots: Map<String, DeviceSnapshot>,
        currentDeviceId: String?,
        controlledDeviceId: String? = null,
    ) = DevicePlayback.group(
        devices = devices,
        snapshots = snapshots,
        currentDeviceId = currentDeviceId,
        controlledDeviceId = controlledDeviceId,
        thisDeviceName = "This Device",
        now = now,
        nowElapsed = 0,
    )

    private fun device(id: String, controlling: Boolean = false) =
        DeviceDto(id = id, name = id, platform = "web", isControlling = controlling)

    private fun entry(
        songId: String = "song",
        playing: Boolean = true,
        online: Boolean = true,
        receivedAt: Long = now,
        progress: Double = 0.0,
        ageSeconds: Double = 0.0,
        receivedAtElapsed: Long = 0,
    ) = DeviceSnapshot(
        snapshot = PlaybackSnapshot(
            songId = songId,
            isPlaying = playing,
            progressSeconds = progress,
            durationSeconds = 200.0,
        ),
        isOnline = online,
        generation = 1,
        snapshotRevision = 1,
        receivedAt = receivedAt,
        ageSeconds = ageSeconds,
        receivedAtElapsed = receivedAtElapsed,
    )
}
