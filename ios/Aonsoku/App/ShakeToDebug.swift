import AonsokuKit
import SwiftUI
import UIKit

extension Notification.Name {
    static let deviceDidShake = Notification.Name("github.realtvop.aonsoku.deviceDidShake")
}

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

/// Presents the native player debug panel (Playback / Info / Logs) when the
/// device is shaken, matching the previous host's developer entry point.
private struct ShakeToDebugModifier: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                DebugPanel()
                    .ignoresSafeArea()
            }
    }
}

private struct DebugPanel: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: DebugViewController())
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

extension View {
    func shakeToOpenDebugPanel() -> some View {
        modifier(ShakeToDebugModifier())
    }
}
