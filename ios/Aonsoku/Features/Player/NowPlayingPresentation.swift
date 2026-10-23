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
    var accessory: PlayerAccessoryLayout?
}

nonisolated enum PlayerArtworkLocation: Hashable {
    case cover
    case header

    static let coordinateSpace = "nowPlayingArtwork"
    static let containerCoordinateSpace = "playerContainer"
}

nonisolated struct PlayerAccessoryLayout: Equatable {
    var frame: CGRect
    var isInline: Bool
}

/// The system accessory supplies layout only. The presentation container
/// owns the sole glass surface, both control layouts, and the artwork.
struct PlayerAccessorySlot: View {
    @Environment(PlayerPresentationState.self) private var presentation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Color.clear
            .frame(height: 36)
            .background { PlayerAccessoryGlassSuppression() }
            .onGeometryChange(for: PlayerAccessoryLayout.self) { proxy in
                PlayerAccessoryLayout(frame: proxy.frame(in: .global), isInline: placement == .inline)
            } action: { layout in
                if layout.frame.width > 0, layout.frame.height > 0 {
                    presentation.accessory = layout
                }
            }
            // Native accessory hosts are recycled while changing placement.
            // Keep the last destination until a new positive frame replaces it.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Keep native accessory placement/minimization without leaving a second
/// glass pill underneath the moving player. Scope this to the public
/// bottomAccessory.contentView's immediate host, never the tab bar itself.
private struct PlayerAccessoryGlassSuppression: UIViewRepresentable {
    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.suppressAccessoryGlass()
    }

    final class MarkerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            suppressAccessoryGlass()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            suppressAccessoryGlass()
        }

        func suppressAccessoryGlass() {
            guard let root = window?.rootViewController else { return }
            suppressAccessoryGlass(in: root)
        }

        private func suppressAccessoryGlass(in controller: UIViewController) {
            if let tabs = controller as? UITabBarController,
               let content = tabs.bottomAccessory?.contentView,
               isDescendant(of: content),
               let host = content.superview,
               host !== tabs.view,
               !tabs.tabBar.isDescendant(of: host) {
                host.isHidden = true
                // Do not restore this during marker recycling: the native
                // accessory remains layout-only for its entire lifetime.
                return
            }
            for child in controller.children {
                suppressAccessoryGlass(in: child)
            }
        }
    }
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
/// Expanded layouts report coordinates before their presentation transforms.
/// The compact destination comes directly from the stationary native accessory.
struct PlayerArtworkSlot: View {
    let location: PlayerArtworkLocation
    var cornerRadius: CGFloat = 8
    var shadowRadius: CGFloat = 0

    @Environment(PlayerPresentationState.self) private var presentation

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(PlayerArtworkLocation.coordinateSpace))
            } action: { rect in
                guard rect.width > 0, rect.height > 0 else { return }
                presentation.artworkFrames[location] = PlayerArtworkFrame(
                    rect: rect, cornerRadius: cornerRadius, shadowRadius: shadowRadius
                )
            }
            .accessibilityHidden(true)
    }
}

/// One persistent container owns the mini player, full player, background,
/// and artwork. Only the committed release morphs it back into the pill.
private struct NowPlayingPresentation: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentation = PlayerPresentationState()
    @State private var viewportCornerRadius: CGFloat = 0
    @State private var palette: ArtworkPalette?

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!router.isNowPlayingPresented)
            .accessibilityHidden(router.isNowPlayingPresented)
            .overlay {
                GeometryReader { proxy in
                    let insets = proxy.safeAreaInsets
                    let width = proxy.size.width + insets.leading + insets.trailing
                    let height = proxy.size.height + insets.top + insets.bottom
                    let full = CGRect(x: 0, y: 0, width: width, height: height)
                    let accessory = accessoryFrame(in: proxy)
                    let pill = accessory.insetBy(dx: 0, dy: -6)
                    let surface = router.isNowPlayingPresented
                        ? full.offsetBy(dx: 0, dy: presentation.dragOffset) : pill
                    let radius = router.isNowPlayingPresented
                        ? expandedRadius : pill.height / 2
                    let shape = PlayerSurfaceShape(frame: surface, cornerRadius: radius)
                    ZStack(alignment: .topLeading) {
                        NowPlayingBackground(
                            palette: palette,
                            intensity: settings.settings.appearance.nowPlayingColorIntensity,
                            isAnimating: player.isPlaying && router.isNowPlayingPresented
                        )
                        .frame(width: surface.width, height: surface.height)
                        .position(x: surface.midX, y: surface.midY)
                        .opacity(backgroundOpacity(viewportHeight: height))
                        NowPlayingView()
                            .padding(insets)
                            .frame(width: width, height: height)
                            .coordinateSpace(name: PlayerArtworkLocation.coordinateSpace)
                            .offset(y: surface.minY)
                            .opacity(router.isNowPlayingPresented ? 1 : 0)
                            .allowsHitTesting(router.isNowPlayingPresented)
                            .accessibilityHidden(!router.isNowPlayingPresented)
                        MiniPlayer(isInline: presentation.accessory?.isInline ?? false)
                            .frame(width: accessory.width, height: accessory.height)
                            .position(x: surface.midX, y: surface.minY + 6 + accessory.height / 2)
                            .opacity(router.isNowPlayingPresented ? 0 : 1)
                            .allowsHitTesting(!router.isNowPlayingPresented)
                            .accessibilityHidden(router.isNowPlayingPresented)
                        sharedArtwork(in: proxy)
                    }
                    .frame(width: width, height: height, alignment: .topLeading)
                    .coordinateSpace(name: PlayerArtworkLocation.containerCoordinateSpace)
                    .clipShape(shape)
                    .background {
                        Color.clear
                            .frame(width: surface.width, height: surface.height)
                            .glassEffect(.regular, in: RoundedRectangle(
                                cornerRadius: radius, style: .continuous
                            ))
                            .position(x: surface.midX, y: surface.midY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .contentShape(shape)
                    .opacity(router.isNowPlayingPresented || presentation.accessory != nil ? 1 : 0)
                    .gesture(PlayerDismissGesture(
                        presentation: presentation,
                        isEnabled: router.isNowPlayingPresented && router.sheet == nil
                    ) { dismiss in
                        withAnimation(presentationAnimation) {
                            if dismiss { router.isNowPlayingPresented = false }
                            presentation.dragOffset = 0
                        }
                    })
                    .background(alignment: .topLeading) {
                        PlayerViewportCornerReader { viewportCornerRadius = $0 }
                            .frame(width: width, height: height)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .offset(x: -insets.leading, y: -insets.top)
                }
                .ignoresSafeArea(.keyboard)
                .animation(
                    presentationAnimation,
                    value: router.isNowPlayingPresented
                )
            }
            .environment(presentation)
            .artworkPalette(coverArtId, into: $palette)
            .onChange(of: router.isNowPlayingPresented) {
                presentation.dragOffset = 0
            }
    }

    private var coverArtId: String? {
        player.currentSong?.coverArtId(preferAlbum: settings.settings.playback.useAlbumCoverForSongs)
    }

    private var expandedRadius: CGFloat {
        viewportCornerRadius > 0 ? viewportCornerRadius : min(presentation.dragOffset / 3, 32)
    }

    private var presentationAnimation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.45, bounce: 0)
    }

    private func backgroundOpacity(viewportHeight: CGFloat) -> Double {
        guard router.isNowPlayingPresented else { return 0 }
        return Double(1 - min(presentation.dragOffset / max(viewportHeight, 1), 1))
    }

    private func accessoryFrame(in proxy: GeometryProxy) -> CGRect {
        let origin = proxy.frame(in: .global).origin
        return presentation.accessory?.frame.offsetBy(
            dx: proxy.safeAreaInsets.leading - origin.x,
            dy: proxy.safeAreaInsets.top - origin.y
        ) ?? CGRect(x: 20, y: proxy.size.height - 100, width: max(proxy.size.width - 40, 0), height: 36)
    }

    private func sharedArtwork(in proxy: GeometryProxy) -> some View {
        let geometry = artworkFrame(in: proxy)
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
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(presentationAnimation, value: presentation.artworkLocation)
            .animation(presentationAnimation, value: presentation.artworkFrames[.cover])
            .animation(presentationAnimation, value: presentation.artworkFrames[.header])
    }

    private func artworkFrame(in proxy: GeometryProxy) -> PlayerArtworkFrame? {
        guard router.isNowPlayingPresented,
              var expanded = presentation.artworkFrames[presentation.artworkLocation] else {
            let accessory = accessoryFrame(in: proxy)
            let isInline = presentation.accessory?.isInline ?? false
            let side: CGFloat = isInline ? 26 : 34
            return PlayerArtworkFrame(
                rect: CGRect(x: accessory.minX + (isInline ? 7 : 10),
                             y: accessory.midY - side / 2, width: side, height: side),
                cornerRadius: isInline ? 4 : 5,
                shadowRadius: 0
            )
        }
        // During a pan the cover stays attached to the expanded surface.
        // Only committing dismissal changes its destination to the pill.
        expanded.rect = expanded.rect.offsetBy(dx: 0, dy: presentation.dragOffset)
        return expanded
    }
}

/// The same mask encloses the background, both control layouts, and cover.
/// Its bounds stay full-width during a pan and morph only after release.
nonisolated private struct PlayerSurfaceShape: Shape {
    var frame: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(frame.animatableData, cornerRadius) }
        set {
            frame.animatableData = newValue.first
            cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: frame)
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
