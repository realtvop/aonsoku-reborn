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
        content
            .onGeometryChange(for: CGRect.self, of: {
                $0.frame(in: .named(PlayerArtworkLocation.containerCoordinateSpace))
            }) {
                presentation.sliderFrames[region] = $0
            }
            .onDisappear { presentation.sliderFrames.removeValue(forKey: region) }
    }
}

/// A UIKit pan can reject slider touches before recognition and cancel
/// button taps once a downward drag begins anywhere in the player.
struct PlayerDismissGesture: UIGestureRecognizerRepresentable {
    let presentation: PlayerPresentationState
    var isEnabled: Bool
    let settle: (_ dismiss: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(presentation: presentation, converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let window = pan.view?.window
        switch pan.state {
        case .began, .changed:
            presentation.dragOffset = max(pan.translation(in: window).y, 0)
        case .ended:
            let distance = presentation.dragOffset
            settle(distance > 100 || (distance > 12 && pan.velocity(in: window).y > 500))
        case .cancelled, .failed:
            settle(false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let presentation: PlayerPresentationState
        let converter: CoordinateSpaceConverter
        private weak var scrollView: UIScrollView?

        init(presentation: PlayerPresentationState, converter: CoordinateSpaceConverter) {
            self.presentation = presentation
            self.converter = converter
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            scrollView = nil
            var view = touch.view
            while let current = view {
                if let scroll = current as? UIScrollView {
                    scrollView = scroll
                    break
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            // UIKit window points and SwiftUI global points can have different
            // safe-area origins. Compare both in this stationary container.
            let location = converter.location(in: .local)
            let translation = converter.translation(in: .local) ?? .zero
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            if presentation.arePlaybackControlsVisible,
               presentation.sliderFrames.values.contains(where: { $0.contains(start) }) {
                return false
            }
            let velocity = pan.velocity(in: pan.view?.window)
            guard velocity.y > abs(velocity.x) else { return false }
            if scrollView != nil, presentation.queueOwnsScrollGestures {
                return false
            }
            // A scrolled lyrics list scrolls back to its top first.
            if let scrollView, scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 1 {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gesture: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }
    }
}
