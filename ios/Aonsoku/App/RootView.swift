import AonsokuKit
import SwiftUI

/// Sign-in or the tabs, following the session.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            switch screen {
            case .restoring:
                Color(.systemBackground)
                    .ignoresSafeArea()
            case .login:
                LoginView()
                    .transition(.opacity)
            case .main:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: screen)
        .accountSwitchAlert()
        .onChange(of: session.isSignedIn) { _, isSignedIn in
            if !isSignedIn {
                router.reset()
            }
        }
    }

    /// A sign-in waiting for the user to decide about the library already
    /// on this device keeps the sign-in screen, and its fields, up.
    private var screen: Screen {
        switch session.state {
        case .restoring: .restoring
        case .signedOut: .login
        case .signedIn: app.isAwaitingAccountDecision ? .login : .main
        }
    }

    private enum Screen {
        case restoring
        case login
        case main
    }
}
