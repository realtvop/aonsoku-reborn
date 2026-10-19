import Foundation

/// Native cross-device coordination: device registration, token refresh,
/// the realtime WebSocket, playback snapshot publication, remote control and
/// handoff. Behavior mirrors `src/coordination/{httpClient,manager,wsClient}.ts`
/// and the playback rules of the former Capacitor coordination plugin.
///
/// Keychain (`aonsoku-coordination`) and UserDefaults keys are shared with the
/// previous app so existing registrations survive the update.
///
/// Event handlers run on the main queue. `state` is safe to read from any
/// thread.
public final class CoordinationService: @unchecked Sendable {
    public static let shared = CoordinationService()

    private let lock = NSLock()
    private var currentState = CoordinationState()
    private var observers: [UUID: @Sendable (CoordinationEvent) -> Void] = [:]

    init() {}

    // MARK: - State

    public var state: CoordinationState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// Subscribes to coordination events. The current state is delivered
    /// immediately as `.stateChanged`. Keep the observation alive; cancelling
    /// or releasing it unsubscribes.
    public func observe(
        _ handler: @escaping @Sendable (CoordinationEvent) -> Void
    ) -> CoordinationObservation {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        let snapshot = currentState
        lock.unlock()
        DispatchQueue.main.async { handler(.stateChanged(snapshot)) }
        return CoordinationObservation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[id] = nil
            self.lock.unlock()
        }
    }

    // MARK: - Lifecycle

    /// Loads the saved config and tokens, then reconnects when this device is
    /// registered. Safe to call more than once.
    public func start() {}

    public func didEnterBackground() {}

    public func willEnterForeground() {}

    public func willTerminate() {}

    // MARK: - Registration and connection

    /// Persists the coordination server and identity URLs.
    public func saveConfig(_ config: CoordinationConfig) {}

    /// Saves `config`, proves the stored Subsonic credentials to the
    /// coordination server, registers this device and opens the realtime
    /// connection.
    public func connect(config: CoordinationConfig, deviceName: String) async throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    /// Opens the realtime connection with a fresh ticket when registered.
    public func reconnect() async {}

    /// Closes the realtime connection and cancels automatic reconnects. The
    /// registration and tokens are kept.
    public func disconnect() {}

    /// Clears this device's tokens and disconnects.
    public func forgetCurrentDevice() async {}

    /// Deletes the coordination account on the server, then forgets this
    /// device.
    public func deleteAccount() async throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    // MARK: - Devices

    public func refreshDevices() async throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    public func renameDevice(id: String, name: String) async throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    public func revokeDevice(id: String) async throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    /// Asks the server to rebroadcast every device's latest snapshot.
    public func requestSnapshots() {}

    // MARK: - Remote control

    /// Starts driving `targetDeviceId`. Lock-screen and media-key commands are
    /// routed to that device until `endControlSession()`.
    public func beginControlSession(targetDeviceId: String) {}

    public func endControlSession() {}

    /// Sends `command` to the controlled device and waits for its
    /// acknowledgement, retrying once on `stale_epoch`.
    @discardableResult
    public func sendActiveControlCommand(
        _ command: CoordinationRemoteCommand
    ) async throws -> CoordinationCommandResult {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    @discardableResult
    public func sendCommand(
        _ command: CoordinationRemoteCommand,
        to targetDeviceId: String
    ) async throws -> CoordinationCommandResult {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    // MARK: - Handoff

    /// Requests that `sourceDeviceId`'s playback continue on this device,
    /// using the cached generation and snapshot revision. The outcome arrives
    /// as `.handoffCommitted` or `.handoffFailed`.
    public func requestHandoffCandidateFromCache(sourceDeviceId: String) throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }
}
