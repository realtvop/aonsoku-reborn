import Foundation
import Perception

/// Text of a toast: a translation key with `{{name}}` arguments, or text
/// that is already localized (such as a server error message).
public enum ToastMessage: Hashable, Sendable {
    case key(String, [String: String] = [:])
    case text(String)
}

/// A short confirmation or error shown above the tab bar.
public struct Toast: Identifiable, Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        case info
        case success
        case error
    }

    public let id: UUID
    public var message: ToastMessage
    public var style: Style
    /// SF Symbol shown before the message; a style default when nil.
    public var systemImage: String?

    public init(
        id: UUID = UUID(),
        message: ToastMessage,
        style: Style = .info,
        systemImage: String? = nil
    ) {
        self.id = id
        self.message = message
        self.style = style
        self.systemImage = systemImage
    }
}

/// Shows one toast at a time. A new toast replaces the current one.
@MainActor
@Perceptible
public final class ToastCenter {
    public private(set) var current: Toast?

    @PerceptionIgnored private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(
        _ message: ToastMessage,
        style: Toast.Style = .info,
        systemImage: String? = nil,
        duration: Duration = .seconds(2.5)
    ) {
        let toast = Toast(message: message, style: style, systemImage: systemImage)
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    public func success(_ key: String, _ args: [String: String] = [:]) {
        show(.key(key, args), style: .success)
    }

    /// Shows an error's description, or `fallbackKey` when it has none.
    public func show(error: Error, fallbackKey: String = "toast.server.error") {
        let description = (error as? LocalizedError)?.errorDescription
        if let description, !description.isEmpty {
            show(.text(description), style: .error)
        } else {
            show(.key(fallbackKey), style: .error)
        }
    }

    /// Dismisses `id`, or whatever is showing when nil.
    public func dismiss(_ id: UUID? = nil) {
        guard let current, id == nil || current.id == id else { return }
        self.current = nil
        dismissTask?.cancel()
        dismissTask = nil
    }
}
