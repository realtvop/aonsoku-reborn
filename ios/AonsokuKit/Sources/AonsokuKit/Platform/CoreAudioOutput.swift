#if os(macOS)

import CoreAudio
import Foundation

enum PlatformAudioOutput {
    static func makeSource() -> AudioOutputSnapshotSource {
        CoreAudioOutputSource()
    }
}

/// Reads the default output device from Core Audio and listens for the
/// properties that change when headphones or other outputs come and go.
struct CoreAudioOutputSource: AudioOutputSnapshotSource {
    func snapshot() -> AudioOutputSnapshot {
        let device = CoreAudioProperties.defaultOutputDevice()
        return AudioOutputSnapshot(
            deviceID: device,
            dataSource: device.flatMap(CoreAudioProperties.outputDataSource(of:)),
            availableDeviceIDs: CoreAudioProperties.outputDevices()
        )
    }

    func startListening(
        _ onChange: @escaping @Sendable () -> Void
    ) -> ObservationToken {
        let listener = CoreAudioOutputListener(onChange: onChange)
        listener.start()
        return ObservationToken { listener.stop() }
    }
}

private enum CoreAudioProperties {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return device
    }

    static func outputDevices() -> Set<AudioObjectID> {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var devices = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return Set(devices.filter(hasOutput(_:)))
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func outputDataSource(of device: AudioObjectID) -> UInt32? {
        var address = address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}

/// Registers the Core Audio property listeners behind one subscription.
///
/// The data-source listener lives on the current default device, so it moves
/// whenever the default changes. Core Audio calls back on one of its own
/// threads; everything is re-dispatched onto a private serial queue.
private final class CoreAudioOutputListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aonsoku.CoreAudioOutputListener")
    private let onChange: @Sendable () -> Void
    private var isRunning = false
    private var dataSourceDevice: AudioObjectID?

    private static let systemSelectors = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices,
    ]

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let listener = Unmanaged<CoreAudioOutputListener>
            .fromOpaque(clientData)
            .takeUnretainedValue()
        listener.queue.async { listener.propertiesChanged() }
        return noErr
    }

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true
            // Core Audio keeps this pointer until stop() removes the listeners.
            _ = Unmanaged.passRetained(self)
            for selector in Self.systemSelectors {
                var address = CoreAudioProperties.address(selector)
                AudioObjectAddPropertyListener(
                    CoreAudioProperties.system, &address, Self.proc, context
                )
            }
            observeDataSource(of: CoreAudioProperties.defaultOutputDevice())
        }
    }

    func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            for selector in Self.systemSelectors {
                var address = CoreAudioProperties.address(selector)
                AudioObjectRemovePropertyListener(
                    CoreAudioProperties.system, &address, Self.proc, context
                )
            }
            observeDataSource(of: nil)
            Unmanaged.passUnretained(self).release()
        }
    }

    private var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func propertiesChanged() {
        guard isRunning else { return }
        let device = CoreAudioProperties.defaultOutputDevice()
        if device != dataSourceDevice { observeDataSource(of: device) }
        onChange()
    }

    private func observeDataSource(of device: AudioObjectID?) {
        if let old = dataSourceDevice {
            var address = CoreAudioProperties.address(
                kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput
            )
            AudioObjectRemovePropertyListener(old, &address, Self.proc, context)
        }
        dataSourceDevice = nil
        guard let device else { return }
        var address = CoreAudioProperties.address(
            kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput
        )
        guard AudioObjectHasProperty(device, &address),
              AudioObjectAddPropertyListener(device, &address, Self.proc, context) == noErr
        else { return }
        dataSourceDevice = device
    }
}

#endif
