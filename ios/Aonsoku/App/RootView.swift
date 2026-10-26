import AonsokuKit
import Perception
import SwiftUI

/// Sign-in or the tabs, following the session.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.themeContext) private var theme

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                switch screen {
                case .restoring:
                    theme.palette.page
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
