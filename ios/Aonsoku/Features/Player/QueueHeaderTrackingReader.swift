import SwiftUI
import UIKit

/// A layout-only marker in the native List. Observe its pan without replacing
/// UIKit's delegate, so native reordering, swipe actions and bounce stay intact.
struct QueueHeaderTrackingReader: UIViewRepresentable {
    let isActive: Bool
    let reduceMotion: Bool
    let onLayout: (UUID, CGRect?, Bool) -> Void
    let onSnap: () -> Void

    func makeUIView(context: Context) -> MarkerView {
        MarkerView()
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.isActive = isActive
        view.reduceMotion = reduceMotion
        view.onLayout = onLayout
        view.onSnap = onSnap
        view.updateObservation()
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.stopObserving(reportRemoval: true)
        view.onLayout = nil
        view.onSnap = nil
    }

    final class MarkerView: UIView {
        var isActive = false
        var reduceMotion = false
        var onLayout: ((UUID, CGRect?, Bool) -> Void)?
        var onSnap: (() -> Void)?

        private weak var scrollView: UIScrollView?
        private var updateLink: UIUpdateLink?
        private var lastFrame: CGRect?
        private var lastVisible = false
        private var pendingSnap: DispatchWorkItem?
        private var awaitingSettlement = false
        private var releasedAt: CFTimeInterval = 0
        private var movedAway = false
        private var sentFeedback = false
        private let owner = UUID()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateObservation()
        }

        func updateObservation() {
            guard window != nil, isActive else {
                stopObserving(reportRemoval: window == nil)
                return
            }
            if scrollView == nil {
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        scrollView = scroll
                        movedAway = false
                        sentFeedback = false
                        scroll.bounces = true
                        scroll.alwaysBounceVertical = true
                        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                        break
                    }
                    ancestor = view.superview
                }
            }
            guard let scrollView, updateLink == nil else { return }
            // Track the stationary viewport: a link associated with the row
            // can stop updating just before that row leaves the visible area.
            let link = UIUpdateLink(view: scrollView) { [weak self] _, _ in
                self?.sampleLayout()
            }
            link.isEnabled = true
            updateLink = link
        }

        func stopObserving(reportRemoval: Bool = false) {
            updateLink?.isEnabled = false
            updateLink = nil
            pendingSnap?.cancel()
            pendingSnap = nil
            awaitingSettlement = false
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
            scrollView = nil
            if reportRemoval, lastFrame != nil {
                let callback = onLayout
                let owner = owner
                // A recycled marker may disappear during a SwiftUI update.
                // Its owner token prevents this callback hiding a newer cell.
                DispatchQueue.main.async { callback?(owner, nil, false) }
            }
            lastFrame = nil
        }

        private func sampleLayout() {
            guard isActive, let scrollView, !bounds.isEmpty else { return }
            let contentFrame = convert(bounds, to: scrollView)
            let frame = contentFrame.offsetBy(dx: -scrollView.bounds.minX, dy: -scrollView.bounds.minY)
            let visible = frame.intersects(CGRect(origin: .zero, size: scrollView.bounds.size))
            if frame != lastFrame || visible != lastVisible {
                lastFrame = frame
                lastVisible = visible
                onLayout?(owner, frame, visible)
            }
            if awaitingSettlement, CACurrentMediaTime() - releasedAt > 0.08,
               !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating {
                awaitingSettlement = false
                snapIfClose()
            }
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            guard isActive, let scrollView else { return }
            switch pan.state {
            case .began:
                pendingSnap?.cancel()
                awaitingSettlement = false
                movedAway = false
                sentFeedback = false
            case .changed:
                let distance = abs(nearestAnchor(in: scrollView) - scrollView.contentOffset.y)
                if distance > 18 { movedAway = true }
                if movedAway, distance < 6 { feedback() }
            case .ended:
                releasedAt = CACurrentMediaTime()
                awaitingSettlement = true
                // Slow releases are attracted immediately; a fling keeps its
                // native momentum and is considered again only after settling.
                if abs(pan.velocity(in: scrollView).y) < 650 {
                    let work = DispatchWorkItem { [weak self] in
                        self?.awaitingSettlement = false
                        self?.snapIfClose()
                    }
                    pendingSnap = work
                    DispatchQueue.main.async(execute: work)
                }
            case .cancelled, .failed:
                pendingSnap?.cancel()
                awaitingSettlement = false
            default:
                break
            }
        }

        private func nearestAnchor(in scroll: UIScrollView) -> CGFloat {
            let header = convert(bounds, to: scroll)
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            let current = header.minY - scroll.adjustedContentInset.top - 8
            let upcoming = current + header.height + 16
            return [current, upcoming]
                .map { min(max($0, minimum), maximum) }
                .min(by: { abs($0 - scroll.contentOffset.y) < abs($1 - scroll.contentOffset.y) }) ?? minimum
        }

        private func snapIfClose() {
            guard isActive, let scrollView, !scrollView.isTracking else { return }
            let target = nearestAnchor(in: scrollView)
            let distance = abs(target - scrollView.contentOffset.y)
            guard distance > 0.75, distance <= 44 else { return }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: !reduceMotion)
            feedback()
        }

        private func feedback() {
            guard !sentFeedback else { return }
            sentFeedback = true
            onSnap?()
        }
    }
}
