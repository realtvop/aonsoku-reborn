import Foundation

/// Where audio is going at one moment, as far as macOS tells us.
struct AudioOutputSnapshot: Equatable, Sendable {
    /// The default output device, if there is one.
    var deviceID: UInt32?
    /// The data source of that device: `hdpn` for the headphone jack, `ispk`
    /// for the internal speakers. Devices without selectable sources have none.
    var dataSource: UInt32?
    /// Every output device that exists right now.
    var availableDeviceIDs: Set<UInt32>

    init(
        deviceID: UInt32? = nil,
        dataSource: UInt32? = nil,
        availableDeviceIDs: Set<UInt32> = []
    ) {
        self.deviceID = deviceID
        self.dataSource = dataSource
        self.availableDeviceIDs = availableDeviceIDs
    }
}

enum AudioRouteClassifier {
    /// The Core Audio four-character code of the headphone data source.
    static let headphonesDataSource = fourCharacterCode("hdpn")

    static func fourCharacterCode(_ value: String) -> UInt32 {
        value.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Names the change between two snapshots with the iOS route-change
    /// vocabulary, or returns nil when the audible route is the same. Only
    /// `.oldDeviceUnavailable` should stop playback.
    static func reason(
        from old: AudioOutputSnapshot,
        to new: AudioOutputSnapshot
    ) -> AudioRouteChangeReason? {
        if old.deviceID != new.deviceID {
            // The device that was playing has disappeared: unplugged,
            // powered off, out of Bluetooth range.
            if let oldDevice = old.deviceID,
               !new.availableDeviceIDs.contains(oldDevice) {
                return .oldDeviceUnavailable
            }
            // The system moved to a device that did not exist a moment ago.
            if let newDevice = new.deviceID,
               !old.availableDeviceIDs.contains(newDevice) {
                return .newDeviceAvailable
            }
            // The user chose another device that was already there.
            return new.deviceID == nil ? .noSuitableRouteForCategory : .override
        }
        guard old.dataSource != new.dataSource else { return nil }
        // Same device, different jack or speaker: the headphones came out/in.
        if old.dataSource == headphonesDataSource { return .oldDeviceUnavailable }
        if new.dataSource == headphonesDataSource { return .newDeviceAvailable }
        return .routeConfigurationChange
    }
}

/// Reads the output state and tells when it may have changed.
protocol AudioOutputSnapshotSource: Sendable {
    func snapshot() -> AudioOutputSnapshot

    /// Calls `onChange` on an arbitrary thread whenever the default device, its
    /// data source or the device list may have changed.
    func startListening(
        _ onChange: @escaping @Sendable () -> Void
    ) -> ObservationToken
}

/// Turns raw output-change notifications into route-change reasons.
final class AudioRouteMonitor: @unchecked Sendable {
    private let source: AudioOutputSnapshotSource
    private let queue: DispatchQueue
    private let now: () -> Date
    private let gracePeriod: TimeInterval
    private let lock = NSLock()
    private var previous = AudioOutputSnapshot()
    /// Devices that stopped being the default output a moment ago. Core Audio
    /// does not say whether the default or the device list updates first, so a
    /// device that is dropped right after the system moved off it is still the
    /// output that went away.
    private var recentDefaults: [UInt32: Date] = [:]

    /// - Parameters:
    ///   - queue: where reasons are delivered.
    ///   - gracePeriod: how long a replaced default device is remembered.
    init(
        source: AudioOutputSnapshotSource,
        queue: DispatchQueue = .main,
        gracePeriod: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.queue = queue
        self.gracePeriod = gracePeriod
        self.now = now
    }

    /// Reports every route change until the token is cancelled or released.
    func start(
        _ handler: @escaping @Sendable (AudioRouteChangeReason) -> Void
    ) -> ObservationToken {
        lock.withLock {
            previous = source.snapshot()
            recentDefaults = [:]
        }
        let listening = source.startListening { [weak self] in
            self?.outputChanged(handler)
        }
        // The token keeps the monitor alive: nothing else holds it.
        return ObservationToken {
            withExtendedLifetime(self) { listening.cancel() }
        }
    }

    private func outputChanged(
        _ handler: @escaping @Sendable (AudioRouteChangeReason) -> Void
    ) {
        let current = source.snapshot()
        let reason: AudioRouteChangeReason? = lock.withLock {
            let moment = now()
            recentDefaults = recentDefaults.filter {
                moment.timeIntervalSince($0.value) < gracePeriod
            }
            var reason = AudioRouteClassifier.reason(from: previous, to: current)
            if reason != .oldDeviceUnavailable {
                let lost = recentDefaults.keys.filter {
                    !current.availableDeviceIDs.contains($0)
                }
                if !lost.isEmpty {
                    reason = .oldDeviceUnavailable
                    lost.forEach { recentDefaults[$0] = nil }
                }
            }
            if let old = previous.deviceID, old != current.deviceID {
                recentDefaults[old] = moment
            }
            previous = current
            return reason
        }
        guard let reason else { return }
        queue.async { handler(reason) }
    }
}
