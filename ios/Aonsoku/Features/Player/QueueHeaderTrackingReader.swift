import SwiftUI
import UIKit

/// A layout-only marker in the native List. Observe its pan without replacing
/// UIKit's delegate, so native reordering, swipe actions and bounce stay intact.
struct QueueHeaderTrackingReader: UIViewRepresentable {
    let isActive: Bool
    let reduceMotion: Bool
    let hasHistory: Bool
    let historyPadding: CGFloat
    let snapAnimation: QueueScrollSnapAnimation
    let onHistoryPadding: (CGFloat) -> Void
    let onLayout: (UUID, CGRect?, Bool, Bool) -> Void
    let onSnap: () -> Void

    func makeUIView(context: Context) -> MarkerView {
        MarkerView()
    }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.isActive = isActive
        view.reduceMotion = reduceMotion
        view.hasHistory = hasHistory
        view.historyPadding = historyPadding
        view.snapAnimation = snapAnimation
        view.onHistoryPadding = onHistoryPadding
        view.onLayout = onLayout
        view.onSnap = onSnap
        view.updateObservation()
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.stopObserving(reportRemoval: true)
        view.onLayout = nil
        view.onSnap = nil
        view.onHistoryPadding = nil
    }

    final class MarkerView: UIView {
        var isActive = false {
            didSet {
                if !isActive {
                    pendingSnap?.cancel()
                    pendingSnap = nil
                    awaitingSettlement = false
                }
            }
        }
        var reduceMotion = false
        var hasHistory = false
        var historyPadding: CGFloat = 0
        weak var snapAnimation: QueueScrollSnapAnimation?
        var onHistoryPadding: ((CGFloat) -> Void)?
        var onLayout: ((UUID, CGRect?, Bool, Bool) -> Void)?
        var onSnap: (() -> Void)?

        private weak var scrollView: UIScrollView?
        private var updateLink: UIUpdateLink?
        private var lastFrame: CGRect?
        private var lastVisible = false
        private var lastPinned = false
        private var pendingSnap: DispatchWorkItem?
        private var awaitingSettlement = false {
            didSet { updateLink?.requiresContinuousUpdates = awaitingSettlement && isActive }
        }
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
            // Keep geometry warm while the mounted queue fades out. Panel
            // activation controls gestures, not the artwork destination.
            guard window != nil else {
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
            link.requiresContinuousUpdates = awaitingSettlement && isActive
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
                DispatchQueue.main.async { callback?(owner, nil, false, false) }
            }
            lastFrame = nil
        }

        private func sampleLayout() {
            guard let scrollView, !bounds.isEmpty else { return }
            let contentFrame = convert(bounds, to: scrollView)
            let frame = contentFrame.offsetBy(dx: -scrollView.bounds.minX, dy: -scrollView.bounds.minY)
            let visible = frame.intersects(CGRect(origin: .zero, size: scrollView.bounds.size))
            let pinned = abs(frame.minY - scrollView.adjustedContentInset.top - 8) <= 1
                && !scrollView.isDragging && !scrollView.isDecelerating
                && snapAnimation?.isAnimating != true
            if frame != lastFrame || visible != lastVisible || pinned != lastPinned {
                lastFrame = frame
                lastVisible = visible
                lastPinned = pinned
                onLayout?(owner, frame, visible, pinned)
            }
            if isActive, !scrollView.isTracking, !scrollView.isDragging,
               !scrollView.isDecelerating, snapAnimation?.isAnimating != true {
                let padding = anchors(in: scrollView).historyPadding
                if abs(padding - historyPadding) > 0.5 { onHistoryPadding?(padding) }
            }
            // A current-track cell can be recycled while browsing history,
            // then reappear after the release. Its new marker still observes
            // the deceleration and settles any partially exposed row.
            if isActive, snapAnimation?.isAnimating != true,
               scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                awaitingSettlement = true
                releasedAt = CACurrentMediaTime()
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
                snapAnimation?.cancel()
                pendingSnap?.cancel()
                awaitingSettlement = false
                movedAway = false
                sentFeedback = false
            case .changed:
                let distance = abs(anchors(in: scrollView).nearest(to: scrollView.contentOffset.y)
                    - scrollView.contentOffset.y)
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

        private func anchors(in scroll: UIScrollView) -> QueueScrollAnchors {
            QueueScrollAnchors(
                header: convert(bounds, to: scroll), viewportHeight: scroll.bounds.height,
                contentHeight: scroll.contentSize.height,
                topInset: scroll.adjustedContentInset.top, bottomInset: scroll.adjustedContentInset.bottom,
                hasHistory: hasHistory, appliedHistoryPadding: historyPadding
            )
        }

        private func snapIfClose() {
            guard isActive, let scrollView, !scrollView.isTracking else { return }
            guard snapAnimation?.isAnimating != true,
                  let target = anchors(in: scrollView).snapTarget(for: scrollView.contentOffset.y),
                  abs(target - scrollView.contentOffset.y) > 0.75 else { return }
            snapAnimation?.start(scrollView, target: target, reduceMotion: reduceMotion)
            feedback()
        }

        private func feedback() {
            guard !sentFeedback else { return }
            sentFeedback = true
            onSnap?()
        }
    }
}

/// Owned by the mounted panel, so a row leaving the viewport cannot interrupt
/// its last few animation frames. Every tick updates native scroll geometry,
/// keeping the sole artwork on the same curve as the metadata.
@MainActor
final class QueueScrollSnapAnimation {
    private var updateLink: UIUpdateLink?
    var isAnimating: Bool { updateLink != nil }

    func start(_ scroll: UIScrollView, target: CGFloat, reduceMotion: Bool) {
        cancel()
        let start = scroll.contentOffset
        // Stop native deceleration before taking ownership of the offset.
        scroll.setContentOffset(start, animated: false)
        guard !reduceMotion else {
            scroll.setContentOffset(CGPoint(x: start.x, y: target), animated: false)
            return
        }
        let startedAt = CACurrentMediaTime()
        let link = UIUpdateLink(view: scroll) { [weak self, weak scroll] _, _ in
            guard let self, let scroll else { self?.cancel(); return }
            guard !scroll.isTracking, !scroll.isDragging else { self.cancel(); return }
            let progress = CGFloat((CACurrentMediaTime() - startedAt) / 0.38)
            let eased = QueueScrollAnchors.easedProgress(progress)
            scroll.setContentOffset(
                CGPoint(x: start.x, y: start.y + (target - start.y) * eased), animated: false
            )
            if progress >= 1 { self.cancel() }
        }
        link.requiresContinuousUpdates = true
        updateLink = link
        link.isEnabled = true
    }

    func cancel() {
        updateLink?.isEnabled = false
        updateLink = nil
    }
}
