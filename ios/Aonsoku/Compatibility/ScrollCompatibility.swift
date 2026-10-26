import SwiftUI
import UIKit

struct AppScrollGeometry: Equatable {
    var contentOffset: CGPoint
    var contentInsets: EdgeInsets
    var contentSize: CGSize
    var containerSize: CGSize
}

enum AppScrollPhase: Equatable {
    case idle, tracking, interacting, decelerating, animating
}

extension View {
    func appOnScrollGeometryChange<Value: Equatable>(
        for type: Value.Type, of transform: @escaping (AppScrollGeometry) -> Value,
        action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(ScrollGeometryObserver(transform: transform, action: action))
    }

    func appOnScrollPhaseChange(_ action: @escaping (AppScrollPhase, AppScrollPhase) -> Void) -> some View {
        modifier(ScrollPhaseObserver(action: action))
    }
}

private struct ScrollGeometryObserver<Value: Equatable>: ViewModifier {
    let transform: (AppScrollGeometry) -> Value
    let action: (Value, Value) -> Void
    @State private var previous: Value?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Value.self) { geometry in
                transform(AppScrollGeometry(
                    contentOffset: geometry.contentOffset, contentInsets: geometry.contentInsets,
                    contentSize: geometry.contentSize, containerSize: geometry.containerSize
                ))
            } action: { action($0, $1) }
        } else {
            content.background(LegacyScrollObserver(onUpdate: { geometry, _ in
                let next = transform(geometry)
                guard next != previous else { return }
                let old = previous ?? next
                previous = next
                action(old, next)
            }))
        }
    }
}

private struct ScrollPhaseObserver: ViewModifier {
    let action: (AppScrollPhase, AppScrollPhase) -> Void
    @State private var previous = AppScrollPhase.idle

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { old, new in
                action(phase(old), phase(new))
            }
        } else {
            content.background(LegacyScrollObserver(onUpdate: { _, phase in
                guard phase != previous else { return }
                let old = previous
                previous = phase
                action(old, phase)
            }))
        }
    }

    @available(iOS 18, *)
    private func phase(_ value: ScrollPhase) -> AppScrollPhase {
        switch value {
        case .idle: .idle
        case .tracking: .tracking
        case .interacting: .interacting
        case .decelerating: .decelerating
        case .animating: .animating
        @unknown default: .idle
        }
    }
}

/// Read the existing scroll view without replacing its delegate or pan gesture.
/// KVO handles geometry; a temporary display link observes the end of deceleration.
struct LegacyScrollObserver: UIViewRepresentable {
    var configure: (UIScrollView) -> Void = { _ in }
    var onUpdate: (AppScrollGeometry, AppScrollPhase) -> Void = { _, _ in }

    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.configure = configure
        view.onUpdate = onUpdate
        view.enqueueSample()
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) { view.stop() }

    final class MarkerView: UIView {
        var configure: (UIScrollView) -> Void = { _ in }
        var onUpdate: (AppScrollGeometry, AppScrollPhase) -> Void = { _, _ in }
        private weak var scroll: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var settleLink: ViewUpdateLink?
        private var samplePending = false
        private var lastGeometry: AppScrollGeometry?
        private var lastPhase = AppScrollPhase.idle
        private var releasedAt: CFTimeInterval = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() } else { enqueueSample() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            enqueueSample()
        }

        func enqueueSample() {
            guard !samplePending, window != nil else { return }
            samplePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.samplePending = false
                guard self.window != nil else { return }
                self.resolveScrollView()
                self.sample()
            }
        }

        func stop() {
            observations.removeAll()
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            settleLink?.isEnabled = false
            settleLink = nil
            scroll = nil
            lastGeometry = nil
        }

        private func resolveScrollView() {
            guard scroll == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let found = view as? UIScrollView { attach(found); return }
                // Prefer a nested shelf/carousel to the outer page's scroll view.
                let candidates = descendantScrollViews(in: view)
                if let found = candidates.min(by: { distance(to: $0) < distance(to: $1) }) {
                    attach(found)
                    return
                }
                ancestor = view.superview
            }
        }

        private func descendantScrollViews(in view: UIView) -> [UIScrollView] {
            view.subviews.filter { $0 !== self }.flatMap { child in
                if let scroll = child as? UIScrollView { return [scroll] }
                return descendantScrollViews(in: child)
            }
        }

        private func distance(to scroll: UIScrollView) -> CGFloat {
            let marker = convert(bounds, to: window)
            let viewport = scroll.convert(scroll.bounds, to: window)
            return abs(marker.minX - viewport.minX) + abs(marker.minY - viewport.minY)
                + abs(marker.width - viewport.width) + abs(marker.height - viewport.height)
        }

        private func attach(_ scroll: UIScrollView) {
            self.scroll = scroll
            configure(scroll)
            observations = [
                scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.enqueueSample() },
                scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.enqueueSample() },
                scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in self?.enqueueSample() },
                scroll.observe(\.adjustedContentInset, options: [.new]) { [weak self] _, _ in self?.enqueueSample() },
            ]
            scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
        }

        @objc private func panChanged() {
            releasedAt = CACurrentMediaTime()
            if settleLink == nil, let scroll {
                let link = ViewUpdateLink(view: scroll) { [weak self] in self?.enqueueSample() }
                link.requiresContinuousUpdates = true
                link.isEnabled = true
                settleLink = link
            }
            enqueueSample()
        }

        private func sample() {
            guard let scroll else { return }
            let inset = scroll.adjustedContentInset
            let geometry = AppScrollGeometry(
                contentOffset: scroll.contentOffset,
                contentInsets: EdgeInsets(top: inset.top, leading: inset.left, bottom: inset.bottom, trailing: inset.right),
                contentSize: scroll.contentSize, containerSize: scroll.bounds.size
            )
            let pan = scroll.panGestureRecognizer.state
            let phase: AppScrollPhase = scroll.isDragging || pan == .changed ? .interacting
                : scroll.isTracking || pan == .began ? .tracking
                : scroll.isDecelerating ? .decelerating : .idle
            if geometry != lastGeometry || phase != lastPhase {
                lastGeometry = geometry
                lastPhase = phase
                onUpdate(geometry, phase)
            }
            if phase == .idle, CACurrentMediaTime() - releasedAt > 0.08 {
                settleLink?.isEnabled = false
                settleLink = nil
            }
        }
    }
}

/// UIKit's passive update link on iOS 18+, with a display-link fallback for
/// views that need presentation-layer sampling on iOS 16/17. Owners stop it
/// when detached; the weak callback target cannot keep an owner alive.
@MainActor
final class ViewUpdateLink {
    private var modern: AnyObject?
    private var legacy: CADisplayLink?
    private let target: FrameTarget

    var isEnabled = false {
        didSet {
            if #available(iOS 18, *), let modern = modern as? UIUpdateLink { modern.isEnabled = isEnabled }
            legacy?.isPaused = !isEnabled
        }
    }
    var requiresContinuousUpdates = false {
        didSet {
            if #available(iOS 18, *), let modern = modern as? UIUpdateLink {
                modern.requiresContinuousUpdates = requiresContinuousUpdates
            }
        }
    }

    init(view: UIView, action: @escaping () -> Void) {
        target = FrameTarget(action: action)
        if #available(iOS 18, *) {
            modern = UIUpdateLink(view: view) { [weak target] _, _ in target?.tick() }
        } else {
            let link = CADisplayLink(target: target, selector: #selector(FrameTarget.tick))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            legacy = link
        }
    }

    deinit { legacy?.invalidate() }

    private final class FrameTarget: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tick() { action() }
    }
}
