import AonsokuKit
import SwiftUI
import UIKit

/// Presentation state shared by the full-width player and its drag handle.
@MainActor
@Observable
final class PlayerPresentationState {
    var dragOffset: CGFloat = 0
    var artworkLocation: PlayerArtworkLocation = .cover
    var artworkFrames: [PlayerArtworkLocation: PlayerArtworkFrame] = [:]
    var sliderFrames: [PlayerSliderRegion: CGRect] = [:]
}

nonisolated enum PlayerArtworkLocation: Hashable {
    case mini
    case cover
    case header

    static let coordinateSpace = "nowPlayingArtwork"
}

nonisolated struct PlayerArtworkFrame: Equatable {
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
    @State private var viewportCornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!router.isNowPlayingPresented)
            .accessibilityHidden(router.isNowPlayingPresented)
            .overlay {
                GeometryReader { proxy in
                    let insets = proxy.safeAreaInsets
                    let width = proxy.size.width + insets.leading + insets.trailing
                    let height = proxy.size.height + insets.top + insets.bottom
                    let slide = router.isNowPlayingPresented
                        ? presentation.dragOffset : height
                    ZStack(alignment: .topLeading) {
                        NowPlayingView()
                            .padding(insets)
                            .frame(width: width, height: height)
                            .coordinateSpace(name: PlayerArtworkLocation.coordinateSpace)
                            .contentShape(.rect)
                            .gesture(PlayerDismissGesture(
                                presentation: presentation,
                                isEnabled: router.isNowPlayingPresented && router.sheet == nil
                            ) { dismiss in
                                withAnimation(artworkAnimation) {
                                    if dismiss { router.isNowPlayingPresented = false }
                                    presentation.dragOffset = 0
                                }
                            })
                            .modifier(PlayerSurfaceCorners(
                                viewportRadius: viewportCornerRadius,
                                slide: slide
                            ))
                            .offset(x: -insets.leading, y: slide - insets.top)
                            .allowsHitTesting(router.isNowPlayingPresented)
                            .accessibilityHidden(!router.isNowPlayingPresented)
                        sharedArtwork(in: proxy, height: height)
                    }
                    .background(alignment: .topLeading) {
                        PlayerViewportCornerReader { viewportCornerRadius = $0 }
                            .frame(width: width, height: height)
                            .offset(x: -insets.leading, y: -insets.top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
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
            .clipShape(RoundedRectangle(
                cornerRadius: geometry?.cornerRadius ?? 0, style: .continuous
            ))
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
        // During a pan the cover stays attached to the expanded surface.
        // Only committing dismissal changes its destination to the pill.
        expanded.rect = expanded.rect.offsetBy(dx: 0, dy: presentation.dragOffset)
        return expanded
    }
}

/// Animate the radius from the actual slide, including programmatic
/// opening/closing. Rounded viewports keep their system-resolved radius.
private struct PlayerSurfaceCorners: ViewModifier, Animatable {
    let viewportRadius: CGFloat
    var slide: CGFloat

    var animatableData: CGFloat {
        get { slide }
        set { slide = newValue }
    }

    func body(content: Content) -> some View {
        let radius = viewportRadius > 0 ? viewportRadius : min(max(slide, 0) / 3, 32)
        content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A stationary, full-viewport probe, so dragging the player cannot change
/// its baseline. UIKit resolves screen/window corners without device tables
/// or private display properties, and invalidates layout when they change.
private struct PlayerViewportCornerReader: UIViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> CornerView {
        CornerView(onChange: onChange)
    }

    func updateUIView(_ view: CornerView, context: Context) {
        view.onChange = onChange
    }

    final class CornerView: UIView {
        var onChange: (CGFloat) -> Void
        private var lastRadius: CGFloat?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            cornerConfiguration = .uniformCorners(radius: .containerConcentric())
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil, !bounds.isEmpty else { return }
            let radius = effectiveRadius(corner: .allCorners)
            guard radius != lastRadius else { return }
            lastRadius = radius
            // Do not mutate SwiftUI state from UIKit's layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.lastRadius == radius else { return }
                self.onChange(radius)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }
    }
}

extension View {
    func nowPlayingPresentation() -> some View {
        modifier(NowPlayingPresentation())
    }
}
