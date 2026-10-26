import AonsokuKit
import Perception
import SwiftUI
import UIKit

extension View {
    /// Shows the app's toasts in a window of their own, so they stay above
    /// sheets and Now Playing. Use once per window root.
    func toastHost(_ app: AppModel) -> some View {
        modifier(ToastHostModifier(app: app))
    }
}

private struct ToastHostModifier: ViewModifier {
    let app: AppModel
    @State private var presenter = ToastWindowPresenter()

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .background {
                    WithPerceptionTracking {
                        WindowSceneReader { scene in
                            presenter.attach(to: scene, app: app)
                        }
                    }
                }
                .appOnChange(of: app.toasts.current?.id) { _, id in
                    presenter.setVisible(id != nil)
                }
        }
    }
}

/// Owns the toast window, which is shown only while a toast is up so it
/// never affects the status bar or rotation the rest of the time.
@MainActor
private final class ToastWindowPresenter {
    private var window: UIWindow?
    private var hideTask: Task<Void, Never>?

    func attach(to scene: UIWindowScene, app: AppModel) {
        guard window?.windowScene !== scene else { return }
        let host = UIHostingController(
            rootView: ToastLayer()
                .themeRoot()
                .environment(app.toasts)
                .environment(app.localizer)
                .environment(app.settings)
        )
        host.view.backgroundColor = .clear
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isUserInteractionEnabled = false
        window.isHidden = app.toasts.current == nil
        self.window = window
    }

    func setVisible(_ isVisible: Bool) {
        hideTask?.cancel()
        if isVisible {
            window?.isHidden = false
        } else {
            // Leaves time for the toast's exit animation.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.window?.isHidden = true
            }
        }
    }
}

/// A window that lets every touch through to the app below.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

/// Reports the window scene a view is shown in.
private struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneReportingView {
        let view = SceneReportingView()
        view.isUserInteractionEnabled = false
        view.onScene = onScene
        return view
    }

    func updateUIView(_ view: SceneReportingView, context: Context) {
        view.onScene = onScene
    }

    final class SceneReportingView: UIView {
        var onScene: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene {
                onScene?(scene)
            }
        }
    }
}

/// The toast itself: a glass capsule under the status bar.
private struct ToastLayer: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let toast = toasts.current
            VStack {
                if let toast {
                    ToastCapsule(toast: toast, text: text(of: toast))
                        .id(toast.id)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            )
                        )
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .animation(.spring(duration: 0.4, bounce: 0.25), value: toast?.id)
            .appFeedback(trigger: toast?.id) { _, id in
                guard id != nil, let toast, settings.settings.playback.hapticFeedback else {
                    return nil
                }
                return switch toast.style {
                case .success: .success
                case .error: .error
                case .info: nil
                }
            }
            .appOnChange(of: toast?.id) { _, id in
                guard id != nil, let toast else { return }
                UIAccessibility.post(notification: .announcement, argument: text(of: toast))
            }
        }
    }

    private func text(of toast: Toast) -> String {
        switch toast.message {
        case let .key(key, args): t(key, args)
        case let .text(text): text
        }
    }
}

private struct ToastCapsule: View {
    let toast: Toast
    let text: String

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(symbolStyle)
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .appGlass(in: .capsule)
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
        }
    }

    private var symbol: String {
        if let systemImage = toast.systemImage { return systemImage }
        return switch toast.style {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var symbolStyle: AnyShapeStyle {
        switch toast.style {
        case .success: AnyShapeStyle(.tint)
        case .error: AnyShapeStyle(.red)
        case .info: AnyShapeStyle(.secondary)
        }
    }
}
