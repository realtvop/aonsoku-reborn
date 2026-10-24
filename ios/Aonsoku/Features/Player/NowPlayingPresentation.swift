import AonsokuKit
import SwiftUI
import UIKit

/// Presentation state shared by the full-width player and its drag handle.
@MainActor
@Observable
final class PlayerPresentationState {
    static func panelAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.45, bounce: 0)
    }

    var dragOffset: CGFloat = 0
    var panel: PlayerPanel?
    var usesWideLayout = false
    var artworkLocation: PlayerArtworkLocation {
        if usesWideLayout || panel == nil { return .cover }
        return panel == .queue ? .queue : .header
    }
    var artworkFrames: [PlayerArtworkLocation: PlayerArtworkFrame] = [:]
    var sliderFrames: [PlayerSliderRegion: CGRect] = [:]
    var arePlaybackControlsVisible = true
    var queueOwnsScrollGestures = false
    var queueHeaderFrame: CGRect?
    var queueHeaderOwner: UUID?
    var queueViewportFrame: CGRect?
    var queueGestureViewportFrame: CGRect?
    var isQueueHeaderPinned = false
    var isQueueHeaderVisible = true
    var pinnedQueueHeaderDismissFrame: CGRect? {
        guard queueOwnsScrollGestures, isQueueHeaderPinned,
              let viewport = queueGestureViewportFrame, let header = queueHeaderFrame else { return nil }
        return CGRect(
            x: viewport.minX, y: viewport.minY + header.minY - 8,
            width: viewport.width, height: header.height + 16
        ).intersection(viewport)
    }
    @ObservationIgnored var prepareQueueForPresentation: (() -> Void)?
    var accessory: PlayerAccessoryLayout?
}

enum PlayerPanel: Hashable {
    case lyrics
    case queue
}

nonisolated enum PlayerArtworkLocation: Hashable {
    case cover
    case header
    case queue

    static let coordinateSpace = "nowPlayingArtwork"
    static let containerCoordinateSpace = "playerContainer"
}

nonisolated struct PlayerAccessoryLayout: Equatable {
    var frame: CGRect
    var compactProgress: CGFloat
}

/// The system accessory supplies layout only. The presentation container
/// owns the sole glass surface, both control layouts, and the artwork.
struct PlayerAccessorySlot: View {
    @Environment(PlayerPresentationState.self) private var presentation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Color.clear
            .frame(height: 36)
            .background {
                PlayerAccessoryLayoutReader(
                    isInline: placement == .inline, previousLayout: presentation.accessory
                ) { layout in
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
private struct PlayerAccessoryLayoutReader: UIViewRepresentable {
    var isInline: Bool
    var previousLayout: PlayerAccessoryLayout?
    var onChange: (PlayerAccessoryLayout) -> Void

    func makeUIView(context: Context) -> MarkerView {
        MarkerView(isInline: isInline, previousLayout: previousLayout, onChange: onChange)
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.update(isInline: isInline, onChange: onChange)
        view.suppressAccessoryGlass()
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.stopObserving()
    }

    final class MarkerView: UIView {
        private var isInline: Bool
        private var onChange: (PlayerAccessoryLayout) -> Void
        private var updateLink: UIUpdateLink?
        private weak var accessoryContent: UIView?
        private var lastLayout: PlayerAccessoryLayout?
        private var startWidth: CGFloat = 0
        private var startProgress: CGFloat = 0

        init(
            isInline: Bool, previousLayout: PlayerAccessoryLayout?,
            onChange: @escaping (PlayerAccessoryLayout) -> Void
        ) {
            self.isInline = isInline
            self.onChange = onChange
            lastLayout = previousLayout
            startWidth = previousLayout?.frame.width ?? 0
            startProgress = previousLayout?.compactProgress ?? (isInline ? 1 : 0)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        func update(isInline: Bool, onChange: @escaping (PlayerAccessoryLayout) -> Void) {
            self.onChange = onChange
            guard self.isInline != isInline else { return }
            startWidth = lastLayout?.frame.width ?? bounds.width
            startProgress = lastLayout?.compactProgress ?? (self.isInline ? 1 : 0)
            self.isInline = isInline
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            suppressAccessoryGlass()
            // Observe UIKit's existing updates; never drive an idle display loop
            // or run a second spring with a different clock from the tab bar.
            let link = UIUpdateLink(view: self) { [weak self] _, _ in
                self?.reportPresentationLayout()
            }
            link.isEnabled = true
            updateLink = link
        }

        func stopObserving() {
            updateLink?.isEnabled = false
            updateLink = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            suppressAccessoryGlass()
        }

        private func reportPresentationLayout() {
            guard let window, let accessoryContent,
                  isDescendant(of: accessoryContent), !bounds.isEmpty else { return }
            // Walk each ancestor's presentation transform. The layout-only
            // accessory is hidden, so its own presentation layer can be nil
            // while an ancestor is still animating its bounds or position.
            var frame = layer.presentation()?.bounds ?? bounds
            var current: CALayer? = layer
            while let model = current, model !== window.layer {
                let visible = model.presentation() ?? model
                frame = visible.convert(frame, to: visible.superlayer)
                current = model.superlayer
            }
            guard current != nil, frame.width > 0, frame.height > 0 else { return }
            let targetWidth = convert(bounds, to: window).width
            let targetProgress: CGFloat = isInline ? 1 : 0
            var progress = lastLayout?.compactProgress ?? targetProgress
            let distance = targetWidth - startWidth
            if lastLayout != nil, abs(distance) > 1 {
                let fraction = min(max((frame.width - startWidth) / distance, 0), 1)
                progress = startProgress + (targetProgress - startProgress) * fraction
            }
            let layout = PlayerAccessoryLayout(frame: frame, compactProgress: progress)
            guard layout != lastLayout else { return }
            lastLayout = layout
            onChange(layout)
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
                accessoryContent = content
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
/// The compact destination follows the native accessory's presentation frame.
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
    @State private var isExpanded = false
    @State private var artworkTransition: ArtworkTransition?

    private struct ArtworkTransition {
        let id = UUID()
        let frame: PlayerArtworkFrame?
        let compactFrame: PlayerArtworkFrame
        let viewport: CGRect
        let dragOffset: CGFloat
        let hidesArtwork: Bool
    }

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
                    let surface = isExpanded
                        ? full.offsetBy(dx: 0, dy: presentation.dragOffset) : pill
                    let radius = isExpanded
                        ? expandedRadius : pill.height / 2
                    let shape = PlayerSurfaceShape(frame: surface, cornerRadius: radius)
                    ZStack(alignment: .topLeading) {
                        NowPlayingBackground()
                        .frame(width: surface.width, height: surface.height)
                        .position(x: surface.midX, y: surface.midY)
                        .opacity(backgroundOpacity(viewportHeight: height))
                        NowPlayingView()
                            .padding(insets)
                            .frame(width: width, height: height)
                            .coordinateSpace(name: PlayerArtworkLocation.coordinateSpace)
                            // Animate the host, never its layout probes or the
                            // native List. Otherwise their intermediate frames
                            // become new artwork destinations mid-transition.
                            .transaction { $0.animation = nil }
                            .offset(y: surface.minY)
                            .opacity(isExpanded ? 1 : 0)
                            .allowsHitTesting(router.isNowPlayingPresented)
                            .accessibilityHidden(!router.isNowPlayingPresented)
                        sharedArtwork(in: proxy)
                    }
                    .environment(\.nowPlayingPalette, palette)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .coordinateSpace(name: PlayerArtworkLocation.containerCoordinateSpace)
                    .clipShape(shape)
                    .background {
                        Color.clear
                            .frame(width: surface.width, height: surface.height)
                            // Keep the content inside the glass effect so its
                            // semantic foreground adapts to the backdrop.
                            .overlay(alignment: .top) {
                                MiniPlayer(compactProgress: presentation.accessory?.compactProgress ?? 0)
                                    .frame(width: accessory.width, height: accessory.height)
                                    .padding(.top, 6)
                                    .opacity(isExpanded ? 0 : 1)
                            }
                            .glassEffect(.regular, in: RoundedRectangle(
                                cornerRadius: radius, style: .continuous
                            ))
                            .position(x: surface.midX, y: surface.midY)
                            .allowsHitTesting(!router.isNowPlayingPresented)
                            .accessibilityHidden(router.isNowPlayingPresented)
                    }
                    .contentShape(shape)
                    .opacity(router.isNowPlayingPresented || presentation.accessory != nil ? 1 : 0)
                    .gesture(PlayerDismissGesture(
                        presentation: presentation,
                        isEnabled: router.isNowPlayingPresented && router.sheet == nil
                    ) { dismiss in
                        if dismiss {
                            // Keep the finger's final offset until the source
                            // geometry has been captured by transition().
                            router.isNowPlayingPresented = false
                        } else {
                            withAnimation(presentationAnimation) { presentation.dragOffset = 0 }
                        }
                    })
                    .background(alignment: .topLeading) {
                        PlayerViewportCornerReader { viewportCornerRadius = $0 }
                            .frame(width: width, height: height)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .offset(x: -insets.leading, y: -insets.top)
                    .onChange(of: router.isNowPlayingPresented, initial: true) { _, expanded in
                        transition(to: expanded, in: proxy)
                    }
                    .onChange(of: presentation.artworkLocation) {
                        if artworkTransition != nil {
                            transition(to: router.isNowPlayingPresented, in: proxy, force: true)
                        }
                    }
                }
                .ignoresSafeArea(.keyboard)
            }
            .environment(presentation)
            .artworkPalette(coverArtId, into: $palette)
    }

    private func transition(to expanded: Bool, in proxy: GeometryProxy, force: Bool = false) {
        guard force || expanded != isExpanded else { return }
        if expanded, presentation.artworkLocation == .queue {
            presentation.prepareQueueForPresentation?()
        }
        let frame = expandedArtworkFrame()
        let viewport = expandedArtworkViewport(in: proxy)
        let snapshot = ArtworkTransition(
            frame: frame, compactFrame: compactArtworkFrame(in: proxy),
            viewport: viewport, dragOffset: presentation.dragOffset,
            hidesArtwork: !expanded && presentation.artworkLocation == .queue
                && (!presentation.isQueueHeaderVisible
                    || frame.map { !$0.rect.intersects(viewport) } == true)
        )
        withAnimation(presentationAnimation, completionCriteria: .logicallyComplete) {
            artworkTransition = snapshot
            isExpanded = expanded
            presentation.dragOffset = 0
        } completion: {
            // An interrupted opening/closing owns a newer pair of endpoints.
            guard artworkTransition?.id == snapshot.id else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { artworkTransition = nil }
        }
    }

    private var coverArtId: String? {
        player.currentSong?.coverArtId(preferAlbum: settings.settings.playback.useAlbumCoverForSongs)
    }

    private var expandedRadius: CGFloat {
        viewportCornerRadius > 0 ? viewportCornerRadius : min(presentation.dragOffset / 3, 32)
    }

    private var presentationAnimation: Animation {
        PlayerPresentationState.panelAnimation(reduceMotion: reduceMotion)
    }

    private func backgroundOpacity(viewportHeight: CGFloat) -> Double {
        guard isExpanded else { return 0 }
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
            // Keep one animatable mask throughout the transition. Replacing
            // Rectangle/EdgeFade branches invalidates the artwork's render
            // subtree; omitting the mask lets queue scrolling paint over the
            // transport controls. This mask follows the same geometry clock.
            .clipShape(PlayerSurfaceShape(frame: artworkViewport(in: proxy), cornerRadius: 0))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .opacity(artworkOpacity)
            .animation(presentationAnimation, value: presentation.artworkLocation)
            .animation(presentationAnimation, value: presentation.artworkFrames[.cover])
            .animation(presentationAnimation, value: presentation.artworkFrames[.header])
    }

    private var artworkOpacity: Double {
        if let artworkTransition { return artworkTransition.hidesArtwork ? 0 : 1 }
        return presentation.artworkLocation == .queue && isExpanded
            && presentation.queueHeaderFrame != nil && !presentation.isQueueHeaderVisible ? 0 : 1
    }

    private func artworkViewport(in proxy: GeometryProxy) -> CGRect {
        if isExpanded, let artworkTransition {
            return artworkTransition.viewport.offsetBy(
                dx: 0, dy: presentation.dragOffset - artworkTransition.dragOffset
            )
        }
        return isExpanded ? expandedArtworkViewport(in: proxy) : fullArtworkViewport(in: proxy)
    }

    private func expandedArtworkViewport(in proxy: GeometryProxy) -> CGRect {
        if presentation.artworkLocation == .queue,
           let viewport = presentation.queueViewportFrame {
            return viewport.offsetBy(dx: 0, dy: presentation.dragOffset)
        }
        return fullArtworkViewport(in: proxy)
    }

    private func fullArtworkViewport(in proxy: GeometryProxy) -> CGRect {
        let insets = proxy.safeAreaInsets
        return CGRect(
            x: 0, y: 0,
            width: proxy.size.width + insets.leading + insets.trailing,
            height: proxy.size.height + insets.top + insets.bottom
        )
    }

    private func artworkFrame(in proxy: GeometryProxy) -> PlayerArtworkFrame? {
        if isExpanded {
            if let artworkTransition, var frame = artworkTransition.frame {
                frame.rect = frame.rect.offsetBy(
                    dx: 0, dy: presentation.dragOffset - artworkTransition.dragOffset
                )
                return frame
            }
            return expandedArtworkFrame()
        }
        return artworkTransition?.compactFrame ?? compactArtworkFrame(in: proxy)
    }

    private func compactArtworkFrame(in proxy: GeometryProxy) -> PlayerArtworkFrame {
        let accessory = accessoryFrame(in: proxy)
        let progress = presentation.accessory?.compactProgress ?? 0
        let side: CGFloat = 30 - 6 * progress
        return PlayerArtworkFrame(
            rect: CGRect(x: accessory.minX + 20 - 6 * progress,
                         y: accessory.midY - side / 2, width: side, height: side),
            cornerRadius: 4.5 - progress,
            shadowRadius: 0
        )
    }

    private func expandedArtworkFrame() -> PlayerArtworkFrame? {
        if presentation.artworkLocation == .queue,
           let header = presentation.queueHeaderFrame,
           let viewport = presentation.queueViewportFrame {
            return PlayerArtworkFrame(
                rect: CGRect(
                    x: viewport.minX + header.minX,
                    y: viewport.minY + header.midY - 32 + presentation.dragOffset,
                    width: 64, height: 64
                ),
                cornerRadius: 8,
                shadowRadius: 10
            )
        }
        guard var expanded = presentation.artworkFrames[
                  presentation.artworkLocation == .queue ? .header : presentation.artworkLocation
              ] else {
            return nil
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
