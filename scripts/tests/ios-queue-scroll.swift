import Foundation
import CoreGraphics

@main
enum QueueScrollAnchorTests {
    static func anchors(
        headerY: CGFloat = 608, headerHeight: CGFloat = 64,
        viewport: CGFloat = 500, content: CGFloat = 2_000,
        topInset: CGFloat = 0, bottomInset: CGFloat = 0,
        hasHistory: Bool = true, padding: CGFloat = 0
    ) -> QueueScrollAnchors {
        QueueScrollAnchors(
            header: CGRect(x: 24, y: headerY, width: 320, height: headerHeight),
            viewportHeight: viewport, contentHeight: content,
            topInset: topInset, bottomInset: bottomInset,
            hasHistory: hasHistory, appliedHistoryPadding: padding
        )
    }

    static func main() {
        let normal = anchors()
        precondition(normal.current == 600 && normal.upcoming == 680)
        precondition(normal.snapTarget(for: 556) == normal.current, "44pt still restores the top row")
        precondition(normal.snapTarget(for: 555.9) == normal.history, "Crossing 44pt enters history")
        let historyTarget = normal.snapTarget(for: 550)!
        precondition(608 - historyTarget >= 500, "No current-row pixel may remain in the viewport")
        precondition(normal.snapTarget(for: historyTarget - 50) == nil, "Older history stays freely scrollable")
        precondition(normal.snapTarget(for: historyTarget) == nil, "An already hidden row stays at rest")
        precondition(normal.snapTarget(for: 645) == normal.upcoming, "Upcoming boundary retains attraction")
        precondition(normal.snapTarget(for: 600) == nil, "No redundant animation at the current anchor")
        precondition(normal.snapTarget(for: 800) == nil, "Distant upcoming rows keep native scrolling")

        let short = anchors(headerY: 128, content: 700, topInset: 20)
        precondition(short.historyPadding == 352, "Short history needs enough leading space")
        let padded = anchors(headerY: 480, content: 1_052, topInset: 20, padding: short.historyPadding)
        precondition(padded.historyPadding == short.historyPadding, "Padding converges after layout")
        precondition(padded.history == -20 && 480 - padded.history! == 500, "Hide the row within legal scroll bounds")
        precondition(padded.snapTarget(for: padded.current - 60) == padded.history)

        let largeType = anchors(headerY: 808, headerHeight: 144, viewport: 620)
        let largeTypeTarget = largeType.snapTarget(for: largeType.current - 80)!
        precondition(808 - largeTypeTarget >= 620, "Dynamic Type must not leave a partial current row")
        let empty = anchors(headerY: 8, hasHistory: false)
        precondition(empty.history == nil && empty.historyPadding == 0)
        precondition(empty.snapTarget(for: -50) == nil, "No artificial history destination without history")
        let resized = anchors(headerY: 480, viewport: 700, topInset: 20, padding: 352)
        precondition(resized.historyPadding == 552, "Viewport growth updates the required space")
        let reduced = anchors(headerY: 680, viewport: 400, topInset: 20, padding: 552)
        precondition(reduced.historyPadding == 252, "Viewport shrink releases excess leading space")

        precondition(QueueScrollAnchors.easedProgress(-1) == 0)
        precondition(QueueScrollAnchors.easedProgress(2) == 1)
        precondition(QueueScrollAnchors.easedProgress(0.25) < 0.25, "Start eases in nonlinearly")
        precondition(QueueScrollAnchors.easedProgress(0.75) > 0.75, "Finish eases out nonlinearly")
        var previous: CGFloat = 0
        for step in 0...100 {
            let value = QueueScrollAnchors.easedProgress(CGFloat(step) / 100)
            precondition(value >= previous && value <= 1, "Animation stays monotonic without overshoot")
            previous = value
        }
        print("Queue scroll geometry and nonlinear animation checks passed.")
    }
}
