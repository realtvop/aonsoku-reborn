import Foundation

#if canImport(UIKit)
import AVFoundation
import MediaPlayer
import UIKit
#endif

/// The output volume `AudioService` reads and changes.
///
/// iOS has a single system volume that only the hardware buttons and an
/// `MPVolumeView` slider can move. On macOS the app owns its volume, so it is
/// kept by the app and `AudioService` scales the player by it.
protocol OutputVolumeControlling: AnyObject {
    /// The current volume, 0...1. Readable from any thread.
    var volume: Float { get }

    /// What `AVPlayer.volume` is multiplied by so the output follows `volume`.
    /// The system volume already scales output on iOS, which makes this 1.
    var playerGain: Float { get }

    /// Reports volume changes made outside the app, such as a hardware button.
    /// The handler may run on any thread.
    func startObserving(_ handler: @escaping @Sendable (Float) -> Void)

    /// Stops reporting changes and releases anything `set` keeps around.
    func stopObserving()

    /// Moves the volume and reports the value that took effect. Main thread.
    func set(
        _ value: Float,
        completion: @escaping (Result<Float, AudioServiceError>) -> Void
    )

    /// The view that hosts the hidden system volume slider. Only iOS needs one.
    func setHostView(_ view: PlatformView?)

    /// Whether the system volume HUD appears when `set` moves the volume.
    /// Only iOS has one.
    func setHUDEnabled(_ enabled: Bool)
}

/// A volume the app owns. The value is saved in preferences and applied to the
/// player, so it never touches the system volume.
final class AppVolumeControl: OutputVolumeControlling, @unchecked Sendable {
    static let defaultsKey = "audio.appVolume.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: Float

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.defaultsKey) as? NSNumber {
            value = Self.clamp(stored.floatValue)
        } else {
            value = 1
        }
    }

    var volume: Float { lock.withLock { value } }

    var playerGain: Float { volume }

    func startObserving(_ handler: @escaping @Sendable (Float) -> Void) {
        // Only the app moves its own volume.
    }

    func stopObserving() {}

    func set(
        _ newValue: Float,
        completion: @escaping (Result<Float, AudioServiceError>) -> Void
    ) {
        let clamped = Self.clamp(newValue)
        lock.withLock { value = clamped }
        defaults.set(clamped, forKey: Self.defaultsKey)
        completion(.success(clamped))
    }

    func setHostView(_ view: PlatformView?) {}

    func setHUDEnabled(_ enabled: Bool) {}

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return max(0, min(1, value))
    }
}

#if canImport(UIKit)

/// Drives the iOS system volume through a hidden `MPVolumeView` slider, the
/// only way an app can change it, and reports changes made with the buttons.
final class SystemVolumeControl: NSObject, OutputVolumeControlling {
    private let session: AVAudioSession
    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private weak var hostView: UIView?
    private var isHUDEnabled = true

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        super.init()
    }

    var volume: Float { session.outputVolume }

    var playerGain: Float { 1 }

    func startObserving(_ handler: @escaping @Sendable (Float) -> Void) {
        observation?.invalidate()
        observation = session.observe(\.outputVolume, options: [.new]) { _, change in
            guard let volume = change.newValue else { return }
            handler(volume)
        }
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    func setHostView(_ view: PlatformView?) {
        guard let view, hostView !== view else { return }
        hostView = view
        if let volumeView {
            volumeView.removeFromSuperview()
            view.addSubview(volumeView)
        }
    }

    func setHUDEnabled(_ enabled: Bool) {
        isHUDEnabled = enabled
        if enabled {
            volumeView?.removeFromSuperview()
            volumeView = nil
        } else if volumeView == nil {
            let view = makeVolumeView()
            hostView?.addSubview(view)
            volumeView = view
        }
    }

    func set(
        _ value: Float,
        completion: @escaping (Result<Float, AudioServiceError>) -> Void
    ) {
        let usesPersistentView = !isHUDEnabled
        let volumeView: MPVolumeView
        if usesPersistentView, let existing = self.volumeView {
            volumeView = existing
        } else {
            volumeView = makeVolumeView()
            hostView?.addSubview(volumeView)
            if usesPersistentView { self.volumeView = volumeView }
        }
        volumeView.layoutIfNeeded()
        guard let slider = Self.findSlider(in: volumeView) else {
            if !usesPersistentView { volumeView.removeFromSuperview() }
            completion(.failure(AudioServiceError(
                code: "volume_control_unavailable",
                message: "System volume control is unavailable."
            )))
            return
        }
        slider.value = value
        slider.sendActions(for: .valueChanged)
        let session = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !usesPersistentView { volumeView.removeFromSuperview() }
            completion(.success(session.outputVolume))
        }
    }

    private func makeVolumeView() -> MPVolumeView {
        let view = MPVolumeView(
            frame: CGRect(x: -2000, y: -2000, width: 120, height: 40)
        )
        view.alpha = 0.001
        return view
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        return view.subviews.lazy.compactMap(findSlider(in:)).first
    }
}

#endif
