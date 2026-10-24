import Foundation
import CoreGraphics

/// Scroll destinations use the row's actual layout, including Dynamic Type.
nonisolated struct QueueScrollAnchors {
    let current: CGFloat
    let upcoming: CGFloat
    let history: CGFloat?
    let historyPadding: CGFloat

    init(
        header: CGRect, viewportHeight: CGFloat, contentHeight: CGFloat,
        topInset: CGFloat, bottomInset: CGFloat,
        hasHistory: Bool, appliedHistoryPadding: CGFloat
    ) {
        let minimum = -topInset
        let maximum = max(minimum, contentHeight + bottomInset - viewportHeight)
        func clamped(_ value: CGFloat) -> CGFloat { min(max(value, minimum), maximum) }
        let currentTop = header.minY - topInset - 8
        current = clamped(currentTop)
        upcoming = clamped(currentTop + header.height + 16)
        // Place even the row's first pixel below the viewport. Short histories
        // get real leading content space rather than relying on rubber banding.
        history = hasHistory ? clamped(header.minY - viewportHeight) : nil
        historyPadding = hasHistory
            ? max(viewportHeight - header.minY - topInset + appliedHistoryPadding, 0) : 0
    }

    func nearest(to offset: CGFloat) -> CGFloat {
        ([current, upcoming] + (history.map { [$0] } ?? []))
            .min { abs($0 - offset) < abs($1 - offset) } ?? current
    }

    func snapTarget(for offset: CGFloat) -> CGFloat? {
        if let history, offset < current, offset > history {
            // Browsing history commits beyond 44pt; never leave the current
            // track partially visible at the bottom after the pan settles.
            return current - offset <= 44 ? current : history
        }
        // Once the current row is fully below the viewport, older history
        // retains its native scrolling and resting positions.
        if let history, offset <= history { return nil }
        let target = nearest(to: offset)
        let distance = abs(target - offset)
        return distance > 0.75 && distance <= 44 ? target : nil
    }

    static func easedProgress(_ progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
