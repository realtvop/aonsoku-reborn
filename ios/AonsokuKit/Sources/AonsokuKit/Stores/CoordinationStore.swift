import Foundation
import Observation

/// A device and its last playback, as listed in the device sheet
/// (web `use-device-playback-models.ts`).
public struct DevicePlaybackSummary: Identifiable, Equatable, Sendable {
    public var device: CoordinationDevice
    public var snapshot: CoordinationDeviceSnapshot?
    /// The snapshot's song, once resolved from the library.
    public var song: Song?
    public var isOnline: Bool
    public var isThisDevice: Bool
    /// Online, playing a song, not controlling another device and not
    /// already controlled.
    public var canBeControlled: Bool
    /// Playback can move here: online, or offline less than eight hours.
    public var canContinueHere: Bool

    public init(
        device: CoordinationDevice,
        snapshot: CoordinationDeviceSnapshot? = nil,
        song: Song? = nil,
        isOnline: Bool = false,
        isThisDevice: Bool = false,
        canBeControlled: Bool = false,
        canContinueHere: Bool = false
    ) {
        self.device = device
        self.snapshot = snapshot
        self.song = song
        self.isOnline = isOnline
        self.isThisDevice = isThisDevice
        self.canBeControlled = canBeControlled
        self.canContinueHere = canContinueHere
    }

    public var id: String { device.id }
}

/// Devices grouped as in the web device panel.
public struct DeviceGroups: Equatable, Sendable {
    public var thisDevice: DevicePlaybackSummary?
    /// Online devices playing a song.
    public var live: [DevicePlaybackSummary]
    /// Offline devices whose snapshot is less than eight hours old.
    public var offlineSnapshots: [DevicePlaybackSummary]
    /// Everything else, including devices controlling another device.
    public var hidden: [DevicePlaybackSummary]

    public init(
        thisDevice: DevicePlaybackSummary? = nil,
        live: [DevicePlaybackSummary] = [],
        offlineSnapshots: [DevicePlaybackSummary] = [],
        hidden: [DevicePlaybackSummary] = []
    ) {
        self.thisDevice = thisDevice
        self.live = live
        self.offlineSnapshots = offlineSnapshots
        self.hidden = hidden
    }

    public static let offlineExpiry: TimeInterval = 8 * 60 * 60
}

/// Progress of moving playback to this device.
public enum HandoffStatus: Equatable, Sendable {
    case idle
    case inProgress(deviceName: String)
    case failed(code: String)
}

/// Cross-device state for the UI: connection, devices, remote control and
/// handoff. While controlling a device it is the player's
/// `RemotePlaybackSource`.
@MainActor
@Observable
public final class CoordinationStore: RemotePlaybackSource {
    public private(set) var state = CoordinationState()
    public private(set) var groups = DeviceGroups()
    public private(set) var handoffStatus = HandoffStatus.idle
    public private(set) var remoteNowPlaying: RemoteNowPlaying?

    @ObservationIgnored public let service: CoordinationService
    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored public weak var toasts: ToastCenter?
    @ObservationIgnored private var observation: CoordinationObservation?
    @ObservationIgnored private var songCache: [String: Song] = [:]
    @ObservationIgnored private var rebuildGeneration = 0

    public init(service: CoordinationService, repository: LibraryRepository) {
        self.service = service
        self.repository = repository
    }

    public var isRegistered: Bool { state.isRegistered }
    public var controlledDeviceId: String? { state.controlledDeviceId }

    /// Observes the service and connects when this device is registered.
    /// Call after sign-in.
    public func start() {
        guard observation == nil else { return }
        observation = service.observe { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        service.start()
    }

    /// Stops observing and disconnects (sign-out).
    public func stop() {
        observation?.cancel()
        observation = nil
        if controlledDeviceId != nil {
            service.endControlSession()
        }
        remoteNowPlaying = nil
        service.disconnect()
    }

    // MARK: Connection

    /// Registers this device with the coordination server and connects.
    public func connect(serverUrl: String, identityUrl: String, deviceName: String) async throws {
        let config = CoordinationConfig(serverUrl: serverUrl, identityUrl: identityUrl)
        service.saveConfig(config)
        try await service.connect(config: config, deviceName: deviceName)
    }

    public func disconnect() {
        stopControlling(showToast: false)
        service.disconnect()
    }

    public func reconnect() async {
        await service.reconnect()
    }
    /// Unregisters this device and clears its tokens.
    public func forgetDevice() async {
        stopControlling(showToast: false)
        await service.forgetCurrentDevice()
    }
    /// Deletes the coordination account and all its devices.
    public func deleteAccount() async throws {
        stopControlling(showToast: false)
        try await service.deleteAccount()
    }

    // MARK: Devices

    public func refreshDevices() async throws {
        try await service.refreshDevices()
        service.requestSnapshots()
    }

    public func rename(deviceId: String, name: String) async throws {
        try await service.renameDevice(id: deviceId, name: name)
    }

    public func revoke(deviceId: String) async throws {
        try await service.revokeDevice(id: deviceId)
    }

    // MARK: Remote control

    /// Controls `deviceId`; the player then projects its playback.
    public func control(deviceId: String) {
        guard deviceId != state.deviceId,
              let device = state.devices.first(where: { $0.id == deviceId }),
              device.revokedAt == nil,
              state.deviceSnapshots[deviceId]?.isOnline == true else { return }
        if controlledDeviceId != nil {
            service.endControlSession()
        }
        service.beginControlSession(targetDeviceId: deviceId)
        service.requestSnapshots()
        toasts?.success(
            "settings.crossDevice.toast.remoteControlSuccess",
            ["name": device.name]
        )
    }

    public func stopControlling() {
        stopControlling(showToast: true)
    }

    public func send(_ command: CoordinationRemoteCommand) async throws {
        let result = try await service.sendActiveControlCommand(command)
        try Self.requireSuccessfulCommand(result)
    }

    static func requireSuccessfulCommand(_ result: CoordinationCommandResult) throws {
        guard case let .error(code, reason) = result else { return }
        throw CoordinationError(code: code, reason: reason)
    }

    // MARK: Handoff

    /// Moves `deviceId`'s playback to this device.
    public func continueHere(from deviceId: String) async {
        let deviceName = state.devices.first(where: { $0.id == deviceId })?.name ?? ""
        handoffStatus = .inProgress(deviceName: deviceName)
        toasts?.show(.key("settings.crossDevice.toast.preparingRelay"))
        do {
            try service.requestHandoffCandidateFromCache(sourceDeviceId: deviceId)
        } catch {
            let code = (error as? CoordinationError)?.code ?? error.localizedDescription
            handoffStatus = .failed(code: code)
            toasts?.show(
                .key("settings.crossDevice.toast.relayFailed", ["code": code]),
                style: .error
            )
        }
    }

    // MARK: - Projection

    func handle(_ event: CoordinationEvent) {
        switch event {
        case let .stateChanged(state):
            apply(state)
        case .handoffCommitted:
            handoffStatus = .idle
            toasts?.success("settings.crossDevice.toast.relaySuccess")
        case let .handoffFailed(_, code):
            handoffStatus = .failed(code: code)
            toasts?.show(
                .key("settings.crossDevice.toast.relayFailed", ["code": code]),
                style: .error
            )
        case let .sessionSuperseded(_, transferredToDevice):
            let deviceName = transferredToDevice.flatMap { id in
                state.devices.first(where: { $0.id == id })?.name
            } ?? ""
            toasts?.show(
                .key(
                    "settings.crossDevice.toast.sessionSuperseded",
                    ["deviceName": deviceName]
                )
            )
        case .remoteCommandExecuted, .capabilityDisabled, .error:
            break
        }
    }

    private func apply(_ newState: CoordinationState) {
        state = newState
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let ids = Set(newState.deviceSnapshots.values.map(\.snapshot.songId))
            .union(newState.deviceSnapshots.values.flatMap(\.snapshot.contextQueue))
            .union(newState.deviceSnapshots.values.flatMap(\.snapshot.userQueue))
        rebuildGroups(state: newState, generation: generation)

        let unresolved = ids.filter { songCache[$0] == nil }
        guard !unresolved.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let songs = (try? await repository.songs(ids: Array(unresolved))) ?? []
            guard rebuildGeneration == generation else { return }
            for song in songs { songCache[song.id] = song }
            rebuildGroups(state: state, generation: generation)
        }
    }

    private func rebuildGroups(state: CoordinationState, generation: Int) {
        guard generation == rebuildGeneration else { return }
        var devices = state.devices
        if let deviceId = state.deviceId,
           !devices.contains(where: { $0.id == deviceId }) {
            devices.insert(CoordinationDevice(
                id: deviceId,
                name: "This device",
                platform: "ios"
            ), at: 0)
        }

        var result = DeviceGroups()
        let now = Date().timeIntervalSince1970
        for device in devices {
            let snapshot = state.deviceSnapshots[device.id]
            let isThisDevice = device.id == state.deviceId
            let isOnline = snapshot?.isOnline ?? false
            let hasSong = !(snapshot?.snapshot.songId.isEmpty ?? true)
            let isFreshOffline = snapshot.map {
                !$0.isOnline && now - $0.lastConfirmedAt < DeviceGroups.offlineExpiry
            } ?? false
            let isControllingOthers = device.isControlling
            let summary = DevicePlaybackSummary(
                device: device,
                snapshot: snapshot,
                song: snapshot.flatMap { songCache[$0.snapshot.songId] },
                isOnline: isOnline,
                isThisDevice: isThisDevice,
                canBeControlled: !isThisDevice && isOnline && hasSong
                    && !isControllingOthers && state.controlledDeviceId != device.id,
                canContinueHere: !isThisDevice && hasSong && !isControllingOthers
                    && (isOnline || isFreshOffline)
            )
            if isThisDevice {
                result.thisDevice = summary
            } else if isControllingOthers {
                result.hidden.append(summary)
            } else if isOnline && hasSong {
                result.live.append(summary)
            } else if hasSong && isFreshOffline {
                result.offlineSnapshots.append(summary)
            } else {
                result.hidden.append(summary)
            }
        }
        groups = result
        rebuildRemoteProjection(state: state)
    }

    private func rebuildRemoteProjection(state: CoordinationState) {
        guard let deviceId = state.controlledDeviceId else {
            remoteNowPlaying = nil
            return
        }
        let device = state.devices.first(where: { $0.id == deviceId })
        guard let device, !device.isRevoked,
              let projection = state.deviceSnapshots[deviceId], projection.isOnline else {
            stopControlling(showToast: true)
            return
        }

        let snapshot = projection.snapshot
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsedSinceSample = max(0, Date().timeIntervalSince1970 - snapshot.sampledAt)
        let sampledAt = max(0, uptime - elapsedSinceSample)
        remoteNowPlaying = RemoteNowPlaying(
            deviceId: deviceId,
            deviceName: device.name,
            song: songCache[snapshot.songId],
            queue: playerQueue(from: snapshot),
            isPlaying: snapshot.isPlaying,
            clock: PlaybackClock(
                position: snapshot.progressSeconds,
                duration: snapshot.durationSeconds,
                rate: snapshot.isPlaying ? 1 : 0,
                sampledAt: sampledAt
            ),
            isShuffleActive: snapshot.shuffle,
            repeatMode: AudioRepeatMode(rawValue: snapshot.repeatMode.rawValue) ?? .off,
            volume: snapshot.volume
        )
    }

    private func playerQueue(from snapshot: CoordinationPlaybackSnapshot) -> PlayerQueue {
        func entry(_ id: String, tier: QueueTier, index: Int) -> QueueEntry {
            QueueEntry(
                song: songCache[id] ?? Song(id: id, title: id),
                tier: tier,
                index: index
            )
        }
        let contextIndex = min(
            max(snapshot.contextIndex ?? 0, 0),
            max(0, snapshot.contextQueue.count - 1)
        )
        let historyEnd = min(
            snapshot.contextQueue.count,
            contextIndex + (snapshot.inUserQueue ? 1 : 0)
        )
        let history = snapshot.contextQueue.prefix(historyEnd).enumerated().map {
            entry($0.element, tier: .context, index: $0.offset)
        }
        let current: QueueEntry? = if snapshot.inUserQueue,
                                      let id = snapshot.userQueue.first {
            entry(id, tier: .user, index: 0)
        } else if snapshot.contextQueue.indices.contains(contextIndex) {
            entry(snapshot.contextQueue[contextIndex], tier: .context, index: contextIndex)
        } else {
            nil
        }
        let hiddenUserCount = snapshot.inUserQueue ? 1 : 0
        let userQueue = snapshot.userQueue.dropFirst(hiddenUserCount).enumerated().map {
            entry($0.element, tier: .user, index: $0.offset + hiddenUserCount)
        }
        let upNext = snapshot.contextQueue.dropFirst(contextIndex + 1).enumerated().map {
            entry($0.element, tier: .context, index: $0.offset + contextIndex + 1)
        }
        return PlayerQueue(
            history: history,
            current: current,
            userQueue: userQueue,
            upNext: upNext,
            source: QueueSource(encoded: snapshot.sourceId),
            sourceName: snapshot.sourceName
        )
    }

    private func stopControlling(showToast: Bool) {
        guard controlledDeviceId != nil || remoteNowPlaying != nil else { return }
        state.controlledDeviceId = nil
        service.endControlSession()
        remoteNowPlaying = nil
        if showToast {
            toasts?.show(.key("settings.crossDevice.toast.exitRemoteControl"))
        }
    }
}
