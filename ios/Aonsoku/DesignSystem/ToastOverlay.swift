import AonsokuKit
import Perception
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension View {
    /// Shows the app's toasts in a window of their own, so they stay above
    /// sheets and Now Playing. Use once per window root.
    func toastHost(_ app: AppModel) -> some View {
        modifier(ToastHostModifier(app: app))
    }
}

#if canImport(UIKit)
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

#else
/// On a Mac the toast is a click-through panel over the window's top edge,
/// one level up so it stays above sheets too: AppKit draws them as windows of
/// their own over the window. It follows the window instead of being its
/// child, since a child window is kept at its parent's level, and like other
/// panels it hides while the app is in the background.
private struct ToastHostModifier: ViewModifier {
    let app: AppModel
    @State private var presenter = ToastPanelPresenter()

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .background {
                    WithPerceptionTracking {
                        HostWindowReader { window in
                            presenter.attach(to: window, app: app)
                        }
                    }
                }
                .appOnChange(of: app.toasts.current?.id) { _, id in
                    presenter.setVisible(id != nil)
                }
        }
    }
}

@MainActor
private final class ToastPanelPresenter {
    private weak var parent: NSWindow?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private static let size = CGSize(width: 560, height: 120)

    func attach(to window: NSWindow, app: AppModel) {
        guard parent !== window else { return }
        detach()
        parent = window
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(
            rootView: ToastLayer()
                .themeRoot()
                .environment(app.toasts)
                .environment(app.localizer)
                .environment(app.settings)
        )
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
            })
        }
        if app.toasts.current != nil { setVisible(true) }
    }

    func setVisible(_ isVisible: Bool) {
        hideTask?.cancel()
        guard let panel, let parent else { return }
        if isVisible {
            position()
            guard parent.isVisible, !parent.isMiniaturized else { return }
            panel.orderFront(nil)
        } else {
            // Leaves time for the toast's exit animation.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// Centered under the title bar and toolbar.
    private func position() {
        guard let panel, let parent else { return }
        let frame = parent.frame
        let contentTop = parent.contentLayoutRect.maxY
        let width = min(Self.size.width, frame.width)
        panel.setFrame(
            CGRect(
                x: frame.minX + (frame.width - width) / 2,
                y: frame.minY + contentTop - Self.size.height,
                width: width,
                height: Self.size.height
            ),
            display: false
        )
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Reports the window a view is shown in.
struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

/// The toast itself: a glass capsule under the status bar or toolbar.
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
                announce(text(of: toast))
            }
        }
    }

    private func announce(_ text: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #else
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
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
