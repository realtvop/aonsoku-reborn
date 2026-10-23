import AonsokuKit
import SwiftUI

/// Presentation state shared by the full-width player and its drag handle.
@MainActor
@Observable
final class PlayerPresentationState {
    var dragOffset: CGFloat = 0
    var artworkLocation: PlayerArtworkLocation = .cover
    var artworkFrames: [PlayerArtworkLocation: PlayerArtworkFrame] = [:]
}

enum PlayerArtworkLocation: Hashable {
    case mini
    case cover
    case header

    static let coordinateSpace = "nowPlayingArtwork"
}

struct PlayerArtworkFrame: Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat
    var shadowRadius: CGFloat

    func interpolated(to other: Self, progress: CGFloat) -> Self {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return Self(
            rect: CGRect(
                x: mix(rect.minX, other.rect.minX),
                y: mix(rect.minY, other.rect.minY),
                width: mix(rect.width, other.rect.width),
                height: mix(rect.height, other.rect.height)
            ),
            cornerRadius: mix(cornerRadius, other.cornerRadius),
            shadowRadius: mix(shadowRadius, other.shadowRadius)
        )
    }
}

/// Layout only: the image itself lives once, above the tabs and player.
/// Global mini-player geometry also works across the system accessory's
/// hosting boundary. Expanded slots use coordinates before the Y slide.
struct PlayerArtworkSlot: View {
    let location: PlayerArtworkLocation
    var cornerRadius: CGFloat = 8
    var shadowRadius: CGFloat = 0

    @Environment(PlayerPresentationState.self) private var presentation

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .onGeometryChange(for: CGRect.self) { proxy in
                location == .mini
                    ? proxy.frame(in: .global)
                    : proxy.frame(in: .named(PlayerArtworkLocation.coordinateSpace))
            } action: { rect in
                guard rect.width > 0, rect.height > 0 else { return }
                presentation.artworkFrames[location] = PlayerArtworkFrame(
                    rect: rect, cornerRadius: cornerRadius, shadowRadius: shadowRadius
                )
            }
            .accessibilityHidden(true)
    }
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
                    let width = proxy.size.width + insets.leading + insets.trailing
                    let height = proxy.size.height + insets.top + insets.bottom
                    ZStack(alignment: .topLeading) {
                        NowPlayingView()
                            .padding(insets)
                            .frame(width: width, height: height)
                            .coordinateSpace(name: PlayerArtworkLocation.coordinateSpace)
                            .offset(x: -insets.leading, y: router.isNowPlayingPresented
                                ? presentation.dragOffset - insets.top
                                : proxy.size.height + insets.bottom)
                            .allowsHitTesting(router.isNowPlayingPresented)
                            .accessibilityHidden(!router.isNowPlayingPresented)
                        sharedArtwork(in: proxy, height: height)
                    }
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

    private func sharedArtwork(in proxy: GeometryProxy, height: CGFloat) -> some View {
        let geometry = artworkFrame(in: proxy, height: height)
        return PlayerArtwork(cornerRadius: 0, size: .large)
            .frame(width: geometry?.rect.width ?? 0, height: geometry?.rect.height ?? 0)
            .clipShape(.rect(cornerRadius: geometry?.cornerRadius ?? 0, style: .continuous))
            .shadow(
                color: .black.opacity(0.35),
                radius: geometry?.shadowRadius ?? 0,
                y: (geometry?.shadowRadius ?? 0) / 2
            )
            .position(x: geometry?.rect.midX ?? 0, y: geometry?.rect.midY ?? 0)
            .opacity(geometry == nil ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(artworkAnimation, value: presentation.artworkLocation)
            .animation(artworkAnimation, value: presentation.artworkFrames[.cover])
            .animation(artworkAnimation, value: presentation.artworkFrames[.header])
    }

    private var artworkAnimation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.5, bounce: 0.15)
    }

    private func artworkFrame(in proxy: GeometryProxy, height: CGFloat) -> PlayerArtworkFrame? {
        let origin = proxy.frame(in: .global).origin
        guard var mini = presentation.artworkFrames[.mini] else { return nil }
        mini.rect = mini.rect.offsetBy(dx: -origin.x, dy: -origin.y)
        guard router.isNowPlayingPresented,
              var expanded = presentation.artworkFrames[presentation.artworkLocation] else {
            return mini
        }
        expanded.rect = expanded.rect.offsetBy(
            dx: -proxy.safeAreaInsets.leading, dy: -proxy.safeAreaInsets.top
        )
        let progress = max(0, 1 - presentation.dragOffset / max(height, 1))
        return mini.interpolated(to: expanded, progress: progress)
    }
}

extension View {
    func nowPlayingPresentation() -> some View {
        modifier(NowPlayingPresentation())
    }
}
