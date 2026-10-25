package github.realtvop.aonsoku.data.coordination

import github.realtvop.aonsoku.i18n.Translations

/** One device as the device panel shows it. */
data class DevicePlaybackModel(
    val device: DeviceDto,
    val isSelf: Boolean,
    val snapshot: PlaybackSnapshot?,
    val isOnline: Boolean,
    /** Online, playing a song, and neither this device nor controlling another one. */
    val canBeControlled: Boolean,
    /** Its song can be taken over here (a handoff). */
    val canBeContinuedLocally: Boolean,
    val progressSeconds: Double,
)

/** The devices of the account, sorted into the sections of the device panel. */
data class DeviceGroups(
    val thisDevice: DevicePlaybackModel? = null,
    /** Online and playing. */
    val live: List<DevicePlaybackModel> = emptyList(),
    /** Offline, but what they played lately can still be continued. */
    val offline: List<DevicePlaybackModel> = emptyList(),
    val hidden: List<DevicePlaybackModel> = emptyList(),
) {
    /** The other devices worth showing on the home page. */
    val others: List<DevicePlaybackModel> get() = live + offline
}

/** The rules of `use-device-playback-models.ts`. */
object DevicePlayback {
    /** How long a snapshot of a device that went offline can still be continued. */
    const val OFFLINE_EXPIRY_MS = 8 * 60 * 60 * 1000L

    /** The id of this device before it is registered. */
    const val LOCAL_DEVICE_ID = "local-device"

    fun group(
        devices: List<DeviceDto>,
        snapshots: Map<String, DeviceSnapshot>,
        currentDeviceId: String?,
        controlledDeviceId: String?,
        thisDeviceName: String,
        now: Long,
        nowElapsed: Long,
    ): DeviceGroups {
        // This device is listed even when the server does not list it (yet).
        val all = if (currentDeviceId == null || devices.none { it.id == currentDeviceId }) {
            listOf(
                DeviceDto(
                    id = currentDeviceId ?: LOCAL_DEVICE_ID,
                    name = thisDeviceName,
                    platform = LOCAL_PLATFORM,
                ),
            ) + devices
        } else {
            devices
        }

        var thisDevice: DevicePlaybackModel? = null
        val live = mutableListOf<DevicePlaybackModel>()
        val offline = mutableListOf<DevicePlaybackModel>()
        val hidden = mutableListOf<DevicePlaybackModel>()
        for (device in all) {
            val isSelf = device.id == currentDeviceId || device.platform == LOCAL_PLATFORM
            val entry = snapshots[device.id]
            val snapshot = entry?.snapshot
            val isOnline = entry?.isOnline ?: false
            val playsSong = snapshot?.hasSong == true
            val freshOffline = entry != null && !entry.isOnline &&
                now - entry.receivedAt < OFFLINE_EXPIRY_MS
            val controlling = device.isControlling
            val model = DevicePlaybackModel(
                device = device,
                isSelf = isSelf,
                snapshot = snapshot,
                isOnline = isOnline,
                canBeControlled = !isSelf && isOnline && playsSong && !controlling &&
                    controlledDeviceId != device.id,
                canBeContinuedLocally = !isSelf && playsSong && !controlling &&
                    (isOnline || freshOffline),
                progressSeconds = entry?.progressAt(nowElapsed) ?: 0.0,
            )
            when {
                isSelf -> thisDevice = model
                controlling -> hidden += model
                isOnline && playsSong -> live += model
                playsSong && freshOffline -> offline += model
                else -> hidden += model
            }
        }
        return DeviceGroups(thisDevice, live, offline, hidden)
    }

    /** What to tell the user when a handoff fails with [code] (`handoff-error-message.ts`). */
    fun handoffError(strings: Translations, code: String, reason: String? = null): String {
        val key = when (code) {
            "target_offline" -> "targetOffline"
            "snapshot_expired" -> "snapshotExpired"
            "handoff_conflict" -> "handoffConflict"
            "source_changed" -> "sourceChanged"
            "source_pause_timeout" -> "sourcePauseTimeout"
            "unsupported_media" -> "unsupportedMedia"
            "device_revoked" -> "deviceRevoked"
            "protocol_incompatible", "capability_disabled" -> "protocolIncompatible"
            "forbidden" -> "forbidden"
            else -> null
        }
        return if (key != null) {
            strings.t("settings.crossDevice.handoffError.$key")
        } else {
            strings.t(
                "settings.crossDevice.handoffError.fallback",
                "reason" to reason?.takeIf { it.isNotBlank() }.orEmpty().ifEmpty { code },
            )
        }
    }

    private const val LOCAL_PLATFORM = "local"
}
