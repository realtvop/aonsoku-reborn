import AonsokuKit
import SwiftUI

/// Presentation state shared by the full-width player and its drag handle.
@MainActor
@Observable
final class PlayerPresentationState {
    var dragOffset: CGFloat = 0
}

/// Keeps the player in the tabs' view tree. Its width never changes during
/// presentation or dismissal; only its vertical offset is animated.
private struct NowPlayingPresentation: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentation = PlayerPresentationState()

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!router.isNowPlayingPresented)
            .accessibilityHidden(router.isNowPlayingPresented)
            .overlay {
                GeometryReader { proxy in
                    let insets = proxy.safeAreaInsets
                    let height = proxy.size.height + insets.top + insets.bottom
                    NowPlayingView()
                        .padding(.top, insets.top)
                        .padding(.bottom, insets.bottom)
                        .frame(width: proxy.size.width, height: height)
                        .offset(y: router.isNowPlayingPresented
                            ? presentation.dragOffset - insets.top
                            : proxy.size.height + insets.bottom)
                        .allowsHitTesting(router.isNowPlayingPresented)
                        .accessibilityHidden(!router.isNowPlayingPresented)
                }
                .ignoresSafeArea(.keyboard)
                .animation(
                    reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.45, bounce: 0),
                    value: router.isNowPlayingPresented
                )
            }
            .environment(presentation)
            .onChange(of: router.isNowPlayingPresented) {
                presentation.dragOffset = 0
            }
    }
}

extension View {
    func nowPlayingPresentation() -> some View {
        modifier(NowPlayingPresentation())
    }
}
