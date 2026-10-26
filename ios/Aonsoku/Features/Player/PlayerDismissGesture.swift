import Perception
import SwiftUI
import UIKit

nonisolated enum PlayerSliderRegion: Hashable {
    case progress
    case volume
}

extension View {
    /// Exclude the whole slider touch target before a container pan begins.
    func playerSliderRegion(_ region: PlayerSliderRegion) -> some View {
        modifier(PlayerSliderRegionModifier(region: region))
    }
}

private struct PlayerSliderRegionModifier: ViewModifier {
    let region: PlayerSliderRegion
    @Environment(PlayerPresentationState.self) private var presentation

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .onGeometryChange(for: CGRect.self, of: {
                    $0.frame(in: .named(PlayerArtworkLocation.containerCoordinateSpace))
                }) {
                    presentation.sliderFrames[region] = $0
                }
                .onDisappear { presentation.sliderFrames.removeValue(forKey: region) }
        }
    }
}

/// Keep the same pan policy on every system; only installation and coordinate
/// conversion differ. The legacy bridge adds a recognizer to its hosting view.
extension View {
    @ViewBuilder
    func playerDismissGesture(
        presentation: PlayerPresentationState, isEnabled: Bool,
        settle: @escaping (Bool) -> Void
    ) -> some View {
        if #available(iOS 18, *) {
            gesture(PlayerDismissGesture(presentation: presentation, isEnabled: isEnabled, settle: settle))
        } else {
            background(LegacyPlayerDismissGesture(
                presentation: presentation, isEnabled: isEnabled, settle: settle
            ))
        }
    }
}

@available(iOS 18, *)
struct PlayerDismissGesture: UIGestureRecognizerRepresentable {
    let presentation: PlayerPresentationState
    var isEnabled: Bool
    let settle: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> PlayerPanHandler {
        let handler = PlayerPanHandler(presentation: presentation)
        handler.startLocation = { _ in
            let location = converter.location(in: .local)
            let translation = converter.translation(in: .local) ?? .zero
            return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        }
        handler.settle = settle
        return handler
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        context.coordinator.makePan(isEnabled: isEnabled)
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.settle = settle
        pan.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handle(pan)
    }
}

private struct LegacyPlayerDismissGesture: UIViewRepresentable {
    let presentation: PlayerPresentationState
    let isEnabled: Bool
    let settle: (Bool) -> Void

    func makeUIView(context: Context) -> MarkerView {
        MarkerView(presentation: presentation)
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.handler.settle = settle
        view.pan.isEnabled = isEnabled
        view.attach()
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) { view.detach() }

    final class MarkerView: UIView {
        let handler: PlayerPanHandler
        let pan: UIPanGestureRecognizer
        private weak var host: UIView?

        init(presentation: PlayerPresentationState) {
            handler = PlayerPanHandler(presentation: presentation)
            pan = handler.makePan(isEnabled: false)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            handler.startLocation = { [weak self] pan in
                guard let self else { return .zero }
                let location = pan.location(in: self)
                let translation = pan.translation(in: self)
                return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            }
            pan.addTarget(handler, action: #selector(PlayerPanHandler.handle(_:)))
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attach()
        }

        func attach() {
            guard window != nil, let superview, host !== superview else { return }
            host?.removeGestureRecognizer(pan)
            host = superview
            superview.addGestureRecognizer(pan)
        }

        func detach() {
            host?.removeGestureRecognizer(pan)
            host = nil
        }
    }
}

@MainActor
final class PlayerPanHandler: NSObject, UIGestureRecognizerDelegate {
    let presentation: PlayerPresentationState
    var startLocation: (UIPanGestureRecognizer) -> CGPoint = { _ in .zero }
    var settle: (Bool) -> Void = { _ in }
    private weak var scrollView: UIScrollView?
    private var pinnedQueueHeaderAtTouch: CGRect?
    private var dismissesFromQueueHeader = false
    private var scrollOffsetAtTouch: CGPoint?

    init(presentation: PlayerPresentationState) { self.presentation = presentation }

    func makePan(isEnabled: Bool) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.isEnabled = isEnabled
        return pan
    }

    @objc func handle(_ pan: UIPanGestureRecognizer) {
        let window = pan.view?.window
        switch pan.state {
        case .began:
            cancelQueuePanIfNeeded()
            presentation.dragOffset = max(pan.translation(in: window).y, 0)
        case .changed:
            presentation.dragOffset = max(pan.translation(in: window).y, 0)
        case .ended:
            let distance = presentation.dragOffset
            settle(distance > 100 || (distance > 12 && pan.velocity(in: window).y > 500))
        case .cancelled, .failed: settle(false)
        default: break
        }
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        scrollView = nil
        pinnedQueueHeaderAtTouch = presentation.pinnedQueueHeaderDismissFrame
        dismissesFromQueueHeader = false
        var view = touch.view
        while let current = view {
            if let scroll = current as? UIScrollView { scrollView = scroll; break }
            view = current.superview
        }
        scrollOffsetAtTouch = scrollView?.contentOffset
        return true
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return false }
        let start = startLocation(pan)
        if presentation.arePlaybackControlsVisible,
           presentation.sliderFrames.values.contains(where: { $0.contains(start) }) { return false }
        let velocity = pan.velocity(in: pan.view?.window)
        guard velocity.y > abs(velocity.x) else { return false }
        if scrollView != nil, presentation.queueOwnsScrollGestures {
            dismissesFromQueueHeader = pinnedQueueHeaderAtTouch?.contains(start) == true
            return dismissesFromQueueHeader
        }
        if let scrollView, scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 1 { return false }
        return true
    }

    private func cancelQueuePanIfNeeded() {
        guard dismissesFromQueueHeader, let scrollView else { return }
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        if let scrollOffsetAtTouch { scrollView.setContentOffset(scrollOffsetAtTouch, animated: false) }
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other.view is UIScrollView
    }
}
