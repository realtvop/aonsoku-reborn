import AonsokuKit
import Perception
import SwiftUI

extension View {
    /// Asks before a sign-in replaces or adopts the library on this
    /// device, while `AppModel` holds a pending account switch.
    func accountSwitchAlert() -> some View {
        modifier(AccountSwitchAlert())
    }
}

private struct AccountSwitchAlert: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    /// The last request shown, kept while the alert dismisses so its
    /// title and message do not change on the way out.
    @State private var request: AccountSwitchRequest?
    /// Apart from the model's request, so a failed erase can bring the
    /// alert back after it has dismissed.
    @State private var isShowing = false

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .alert(title, isPresented: $isShowing, presenting: request) { request in
                    if request.canKeepLibrary {
                        Button(t("native.accountSwitch.keep")) {
                            decide { try app.keepLibraryData() }
                        }
                    }
                    Button(t("native.accountSwitch.erase"), role: .destructive) {
                        decide { try app.confirmAccountSwitch() }
                    }
                    Button(t("generic.cancel"), role: .cancel) {
                        app.cancelAccountSwitch()
                    }
                } message: { request in
                    Text(message(for: request))
                }
                .onChange(of: app.pendingAccountSwitch, initial: true) { _, pending in
                    if let pending { request = pending }
                    isShowing = pending != nil
                }
        }
    }

    private var title: String {
        switch request?.reason {
        case .differentAccount: t("native.accountSwitch.different.title")
        case .differentServer: t("native.accountSwitch.server.title")
        case .unknownOwner, nil: t("native.accountSwitch.unknown.title")
        }
    }

    private func message(for request: AccountSwitchRequest) -> String {
        let user = request.username
        let server = Self.displayServer(request.serverUrl)
        switch request.reason {
        case let .differentAccount(previousServer, previousUsername):
            return t("native.accountSwitch.different.message", [
                "user": user,
                "server": server,
                "previousUser": previousUsername,
                "previousServer": Self.displayServer(previousServer),
            ])
        case let .differentServer(previousServer):
            return t("native.accountSwitch.server.message", [
                "user": user,
                "server": server,
                "previousServer": Self.displayServer(previousServer),
            ])
        case .unknownOwner:
            return t("native.accountSwitch.unknown.message", [
                "user": user,
                "server": server,
            ])
        }
    }

    /// Runs the user's choice. When erasing or keeping fails, the request
    /// stays pending: the error shows above the alert, which comes back so
    /// the user can try again or cancel.
    private func decide(_ decision: () throws -> Void) {
        do {
            try decision()
            toasts.success("toast.server.success")
        } catch {
            toasts.show(error: error)
            Task {
                try? await Task.sleep(for: .seconds(1))
                isShowing = app.isAwaitingAccountDecision
            }
        }
    }

    /// A server address without its scheme or trailing slash, as people
    /// write it: "music.example.com", "192.168.1.2:4533/navidrome".
    static func displayServer(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else {
            return url
        }
        var text = host
        if let port = components.port {
            text += ":\(port)"
        }
        let path = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        return text + path
    }
}

private extension AccountSwitchRequest {
    /// Another user's library is never adopted, so keeping it is offered
    /// only when the library could be this account's.
    var canKeepLibrary: Bool {
        switch reason {
        case .differentAccount: false
        case .differentServer, .unknownOwner: true
        }
    }
}
