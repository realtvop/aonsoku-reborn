import AonsokuKit
import SwiftUI

/// Sign-in or the tabs, following the session.
struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            switch session.state {
            case .restoring:
                Color(.systemBackground)
                    .ignoresSafeArea()
            case .signedOut:
                LoginView()
                    .transition(.opacity)
            case .signedIn:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: session.isSignedIn)
        .onChange(of: session.isSignedIn) { _, isSignedIn in
            if !isSignedIn {
                router.reset()
            }
        }
    }
}
