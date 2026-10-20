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

    public init(service: CoordinationService, repository: LibraryRepository) {
        self.service = service
        self.repository = repository
    }

    public var isRegistered: Bool { state.isRegistered }
    public var controlledDeviceId: String? { state.controlledDeviceId }

    /// Observes the service and connects when this device is registered.
    /// Call after sign-in.
    public func start() {}

    /// Stops observing and disconnects (sign-out).
    public func stop() {}

    // MARK: Connection

    /// Registers this device with the coordination server and connects.
    public func connect(serverUrl: String, identityUrl: String, deviceName: String) async throws {}
    public func disconnect() {}
    public func reconnect() async {}
    /// Unregisters this device and clears its tokens.
    public func forgetDevice() async {}
    /// Deletes the coordination account and all its devices.
    public func deleteAccount() async throws {}

    // MARK: Devices

    public func refreshDevices() async throws {}
    public func rename(deviceId: String, name: String) async throws {}
    public func revoke(deviceId: String) async throws {}

    // MARK: Remote control

    /// Controls `deviceId`; the player then projects its playback.
    public func control(deviceId: String) {}
    public func stopControlling() {}

    public func send(_ command: CoordinationRemoteCommand) async throws {}

    // MARK: Handoff

    /// Moves `deviceId`'s playback to this device.
    public func continueHere(from deviceId: String) async {}
}
