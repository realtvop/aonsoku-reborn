import CoreGraphics
import Foundation

// The synced lyrics' layout and motion, ported from Apple Music Like Lyrics
// (`@applemusic-like-lyrics/core` 0.2.0, the engine behind the web player's
// lyrics). Nothing here touches UIKit or SwiftUI so that the maths can be
// checked on a Mac without a simulator (`scripts/test-ios-lyrics-motion.sh`).

/// A damped spring in AMLL's parameterization.
nonisolated struct LyricsSpringParams: Equatable {
    var mass: Double
    var damping: Double
    var stiffness: Double

    /// `posYSpringParams`, moving a line.
    static let position = LyricsSpringParams(mass: 0.9, damping: 15, stiffness: 90)
    /// `scaleSpringParams`, resizing a line.
    static let scale = LyricsSpringParams(mass: 2, damping: 25, stiffness: 100)
    /// A fast, almost critically damped spring standing in for the web's
    /// 0.5s CSS transition after a seek, and for Reduce Motion.
    static let quick = LyricsSpringParams(mass: 1, damping: 40, stiffness: 400)
}

/// One animated value. Setting a target restarts the closed-form solution
/// from the current position and velocity; a delayed target keeps moving
/// toward the old one until the delay elapses, like AMLL's queued targets.
nonisolated struct LyricsSpring {
    private(set) var params: LyricsSpringParams
    private(set) var position: Double
    private(set) var target: Double
    private var origin: Double
    private var originVelocity = 0.0
    private var elapsed = 0.0
    private var pending: (target: Double, remaining: Double)?

    init(_ value: Double, params: LyricsSpringParams) {
        self.params = params
        position = value
        target = value
        origin = value
    }

    var velocity: Double {
        Self.displacement(origin - target, originVelocity, params, at: elapsed).velocity
    }

    var isSettled: Bool {
        pending == nil && abs(target - position) < 0.01 && abs(velocity) < 0.05
    }

    mutating func snap(to value: Double) {
        position = value
        target = value
        origin = value
        originVelocity = 0
        elapsed = 0
        pending = nil
    }

    mutating func retarget(_ value: Double, delay: Double = 0) {
        if delay > 0 {
            pending = (value, delay)
        } else {
            pending = nil
            restart(toward: value)
        }
    }

    mutating func setParams(_ newValue: LyricsSpringParams) {
        guard newValue != params else { return }
        let current = velocity
        params = newValue
        origin = position
        originVelocity = current
        elapsed = 0
    }

    /// Moves the coordinate system under the spring so that the line stays
    /// where it is on screen while its layout position changes.
    mutating func shiftCoordinates(by delta: Double) {
        position += delta
        target += delta
        origin += delta
        if let pending { self.pending = (pending.target + delta, pending.remaining) }
    }

    mutating func advance(_ dt: Double) {
        elapsed += dt
        position = target + Self.displacement(origin - target, originVelocity, params, at: elapsed).offset
        if let current = pending {
            let remaining = current.remaining - dt
            if remaining <= 0 {
                pending = nil
                restart(toward: current.target)
            } else {
                pending = (current.target, remaining)
            }
        }
        if isSettled { snap(to: target) }
    }

    private mutating func restart(toward value: Double) {
        let current = velocity
        origin = position
        originVelocity = current
        target = value
        elapsed = 0
    }

    /// Distance from the target and its rate of change after `t` seconds,
    /// for a start `offset` away moving at `velocity`.
    static func displacement(
        _ offset: Double, _ velocity: Double, _ p: LyricsSpringParams, at t: Double
    ) -> (offset: Double, velocity: Double) {
        let discriminant = 4 * p.mass * p.stiffness - p.damping * p.damping
        if discriminant > 0, p.damping / (2 * (p.mass * p.stiffness).squareRoot()) < 1 {
            let root = discriminant.squareRoot()
            let omega = 0.5 * root / p.mass
            let alpha = -0.5 * p.damping / p.mass
            let b = (p.damping * offset + 2 * p.mass * velocity) / root
            let decay = exp(alpha * t)
            let cosine = cos(omega * t)
            let sine = sin(omega * t)
            let value = offset * cosine + b * sine
            let slope = -offset * omega * sine + b * omega * cosine
            return (decay * value, decay * (alpha * value + slope))
        }
        let rate = -(p.stiffness / p.mass).squareRoot()
        let g = rate * offset - velocity
        let decay = exp(rate * t)
        return ((offset - t * g) * decay, decay * (rate * (offset - t * g) - g))
    }
}

/// Sizes the web derives from the player's font size (`--amll-lp-font-size`)
/// and its project overrides in `src/index.css`.
nonisolated enum LyricsMetrics {
    /// `max(8vw, 12px)` below 768pt wide, like AMLL's mobile rule. Wider
    /// windows use `max(5vh, 2.5vw)` there, which is far too large for a
    /// tablet's lyrics column, so it is capped.
    static func baseSize(containerWidth: Double, containerHeight: Double) -> Double {
        if containerWidth <= 768 { return max(0.08 * containerWidth, 12) }
        return min(max(max(0.05 * containerHeight, 0.025 * containerWidth), 12), 40)
    }

    /// The original text: `1.16em`. It scales to `0.862` while the line is
    /// not the current one, which is exactly one em.
    static func mainSize(base: Double) -> Double { base * 1.16 }
    static let inactiveMainScale = 0.862069
    /// Translation and romanization: `max(.5em, 10px)`.
    static func subSize(base: Double) -> Double { max(base * 0.5, 10) }
    /// `padding: .5em 1em`, or 20px at the sides on small screens.
    static func verticalPadding(base: Double) -> Double { base * 0.5 }
    static func horizontalPadding(width: Double, base: Double) -> Double {
        width <= 500 ? 20 : base
    }

    /// The interlude dots: a diameter of `clamp(.5em, 1vh, 3em)` with
    /// `2.5%` of the width above and below.
    static func dotDiameter(base: Double, containerHeight: Double) -> Double {
        max(0.5 * base, min(0.01 * containerHeight, 3 * base))
    }

    static func dotsHeight(base: Double, width: Double, containerHeight: Double) -> Double {
        dotDiameter(base: base, containerHeight: containerHeight) + 2 * 0.025 * width
    }
}

nonisolated struct LyricsLineTiming: Equatable {
    var start: Double
    var end: Double
}

/// Where the three interlude dots are and how they look.
nonisolated struct LyricsDotsState: Equatable {
    var isVisible = false
    /// Top of the dots' slot in content coordinates.
    var top = 0.0
    var scale = 0.0
    var opacities = [0.0, 0.0, 0.0]
}

nonisolated struct LyricsLineAppearance: Equatable {
    var isActive = false
    var blur = 0.0
}

/// Lays lyrics out and moves them like AMLL's `LyricPlayerBase`.
///
/// Lines live in content coordinates at a "natural" position (stacked, with a
/// slot for the interlude dots). A spring per line moves it away from that
/// position and back, the way AMLL animates a line toward its layout slot.
/// Following the song moves the scroll view's offset in one step and every
/// line springs into place with a growing delay, which is what gives the
/// staggered motion. While the user browses, the layout holds still.
nonisolated final class LyricsMotionEngine {
    enum Mode {
        /// Normal following: each line springs with its stagger delay.
        case animated
        /// A seek or tap: no stagger, a quick spring.
        case quick
        /// Positions jump to their slots.
        case snap
    }

    static let alignFraction = 0.35
    static let staggerStep = 0.05
    static let interludeMinimum = 4.0

    private let timings: [LyricsLineTiming]
    private let processed: [LyricsLineTiming]
    private var heights: [Double] = []
    private var viewport = 0.0
    private var dotsHeight = 0.0
    private var padding = 0.0
    private var hasLayout = false

    private var activeIndex: Int?
    private var scrollIndex = 0
    private var time = 0.0
    private var interlude: (start: Double, end: Double)?

    private var offsetSprings: [LyricsSpring]
    private var scaleSprings: [LyricsSpring]

    var blurEnabled = true
    /// AMLL softens blur on windows up to 1024pt wide.
    var blurScale = 0.8
    var reducedMotion = false

    private(set) var naturalTops: [Double]
    private(set) var appearances: [LyricsLineAppearance]
    private(set) var followOffset = 0.0
    private(set) var contentHeight = 0.0
    /// Where the last line ends, in content coordinates.
    private(set) var linesBottom = 0.0
    /// Counts layouts and appearance changes, so that a caller knows when to
    /// read every line again rather than only the ones that moved.
    private(set) var revision = 0
    private(set) var dots = LyricsDotsState()
    private(set) var offsets: [Double]
    private(set) var scales: [Double]

    init(timings: [LyricsLineTiming]) {
        self.timings = timings
        var adjusted = timings
        // `setLyricLines`: a line may start up to a second early without
        // overlapping the one before it; the first line always does.
        for index in stride(from: timings.count - 1, through: 0, by: -1) {
            if index > 0 {
                adjusted[index].start = max(
                    min(timings[index - 1].end, timings[index].start), timings[index].start - 1
                )
            } else {
                adjusted[index].start = max(0, timings[index].start - 1)
            }
        }
        processed = adjusted
        offsetSprings = Array(repeating: LyricsSpring(0, params: .position), count: timings.count)
        scaleSprings = Array(repeating: LyricsSpring(100, params: .scale), count: timings.count)
        naturalTops = Array(repeating: 0, count: timings.count)
        appearances = Array(repeating: LyricsLineAppearance(), count: timings.count)
        offsets = Array(repeating: 0, count: timings.count)
        scales = Array(repeating: 1, count: timings.count)
    }

    var lineCount: Int { timings.count }
    var isLaidOut: Bool { hasLayout }

    var isSettled: Bool {
        !offsetSprings.contains { !$0.isSettled } && !scaleSprings.contains { !$0.isSettled }
    }

    // MARK: Measurements

    /// Line heights include their padding. Returns the scroll offset to use
    /// when this was the first layout or the measurements changed.
    func setMeasurements(
        heights newHeights: [Double], viewportHeight: Double, dotsHeight newDotsHeight: Double,
        followsScroll: Bool
    ) -> Double? {
        guard newHeights.count == timings.count, viewportHeight > 0 else { return nil }
        let changed = newHeights != heights || dotsHeight != newDotsHeight
        let viewportChanged = abs(viewportHeight - viewport) > 0.5
        heights = newHeights
        dotsHeight = newDotsHeight
        viewport = viewportHeight
        guard changed || viewportChanged || !hasLayout else { return nil }
        if !hasLayout {
            (activeIndex, scrollIndex) = resolvedIndices(at: time, seeking: true)
        }
        // Only follow mode re-anchors on a viewport change; browsing keeps its
        // layout and merely gets a different scroll range.
        guard changed || !hasLayout || followsScroll else {
            contentHeight = computeContentHeight()
            return nil
        }
        return relayout(mode: .snap, followsScroll: followsScroll, currentOffset: followOffset)
    }

    // MARK: Time

    /// Advances the playback position. Re-lays the lines out when the current
    /// line changes (or after a seek) and returns the scroll offset to apply
    /// when `followsScroll` holds.
    func update(
        time newTime: Double, seeking: Bool, followsScroll: Bool, currentOffset: Double
    ) -> Double? {
        time = newTime
        guard hasLayout else { return nil }
        let (newActive, newScroll) = resolvedIndices(at: newTime, seeking: seeking)
        let changed = newActive != activeIndex || newScroll != scrollIndex
        activeIndex = newActive
        scrollIndex = newScroll
        guard changed || seeking else {
            refreshDots()
            return nil
        }
        return relayout(
            mode: seeking ? .quick : .animated, followsScroll: followsScroll,
            currentOffset: currentOffset
        )
    }

    /// Jumps to a position without any motion, e.g. when the page appears.
    func snapLayout(time newTime: Double) -> Double? {
        time = newTime
        guard hasLayout || !heights.isEmpty else { return nil }
        (activeIndex, scrollIndex) = resolvedIndices(at: newTime, seeking: true)
        return relayout(mode: .snap, followsScroll: true, currentOffset: followOffset)
    }

    /// Blur follows the user's browsing; only appearance changes.
    func setBlurEnabled(_ enabled: Bool) {
        guard blurEnabled != enabled else { return }
        blurEnabled = enabled
        guard hasLayout else { return }
        refreshAppearance()
    }

    func setReducedMotion(_ value: Bool) {
        guard reducedMotion != value else { return }
        reducedMotion = value
        guard hasLayout else { return }
        refreshAppearance()
    }

    // MARK: Frames

    /// Steps every moving line and returns the ones whose offset or scale
    /// changed.
    func advance(_ dt: Double) -> [Int] {
        var changed: [Int] = []
        for index in 0..<timings.count {
            if offsetSprings[index].isSettled, scaleSprings[index].isSettled { continue }
            offsetSprings[index].advance(dt)
            scaleSprings[index].advance(dt)
            let offset = offsetSprings[index].position
            let scale = scaleSprings[index].position / 100
            if offset != offsets[index] || scale != scales[index] {
                offsets[index] = offset
                scales[index] = scale
                changed.append(index)
            }
        }
        refreshDots()
        return changed
    }

    // MARK: Layout

    /// The line that is sung now. `scrollIndex` is the line the layout is
    /// aligned to, which keeps its place between lines.
    private func resolvedIndices(at time: Double, seeking: Bool) -> (Int?, Int) {
        let active = processed.firstIndex { $0.start <= time && time < $0.end }
        if let active { return (active, active) }
        if seeking, let next = processed.firstIndex(where: { $0.start >= time }) {
            return (nil, next)
        }
        return (nil, min(scrollIndex, max(timings.count - 1, 0)))
    }

    /// `getCurrentInterlude`: the gap before the first line, or between two.
    private func currentInterlude() -> (start: Double, end: Double, line: Int)? {
        guard activeIndex == nil else { return nil }
        let now = time + 0.02
        let index = scrollIndex
        if index == 0 {
            guard let first = processed.first, first.start > 0 else { return nil }
            if first.start > now {
                return (now, max(now, first.start - 0.25), -2)
            }
            if processed.count > 1, processed[1].start > now, first.end < now {
                return (max(first.end, now), processed[1].start, 0)
            }
        } else if processed.indices.contains(index + 1), processed[index].end > 0,
                  processed[index + 1].start > 0 {
            if processed[index + 1].start > now, processed[index].end < now {
                return (max(processed[index].end, now), processed[index + 1].start, index)
            }
            if processed.indices.contains(index + 2), processed[index + 2].start > 0,
               processed[index + 2].start > now, processed[index + 1].end < now {
                return (max(processed[index + 1].end, now), processed[index + 2].start, index + 1)
            }
        }
        return nil
    }

    private func computeContentHeight() -> Double {
        let total = heights.reduce(0, +)
        return padding + total + (dots.isVisible ? dotsHeight : 0) + viewport * (1 - Self.alignFraction)
    }

    private func relayout(mode: Mode, followsScroll: Bool, currentOffset: Double) -> Double? {
        guard heights.count == timings.count, viewport > 0 else { return nil }
        let count = timings.count
        let previousTops = naturalTops
        let hadLayout = hasLayout
        if followsScroll || !hadLayout { padding = Self.alignFraction * viewport }

        interlude = nil
        var span = 0.0
        var alignIndex = scrollIndex
        var dotsLine = -3
        if let found = currentInterlude() {
            span = found.end - found.start
            if span >= Self.interludeMinimum {
                interlude = (found.start, found.end)
                dotsLine = found.line == -2 ? scrollIndex : scrollIndex + 1
                if found.line + 1 >= 0, found.line + 1 < count { alignIndex = found.line + 1 }
            }
        }

        let slice = min(max(alignIndex, 0), count)
        let above = heights[0..<slice].reduce(0, +)
        let newFollow = padding + above - Self.alignFraction * viewport

        var screen = Self.alignFraction * viewport - above
        var natural = padding
        var delay = 0.0
        var step = (mode == .snap || reducedMotion) ? 0 : Self.staggerStep
        var dotsPlaced = false
        var newTops = [Double](repeating: 0, count: count)
        var scaleTargets = [Double](repeating: 100, count: count)
        var delays = [Double](repeating: 0, count: count)
        var newDots = LyricsDotsState()
        let activeSet = activeIndex.map { Set([$0]) } ?? []
        let lastActive = activeIndex.map(Double.init) ?? -Double.infinity

        for line in 0..<count {
            let isActive = activeSet.contains(line)
            let inFocus = isActive || (Double(line) >= Double(scrollIndex) && Double(line) < lastActive)
            if !dotsPlaced, dotsLine == line {
                dotsPlaced = true
                newDots = LyricsDotsState(isVisible: true, top: natural)
                screen += dotsHeight
                natural += dotsHeight
            }
            newTops[line] = natural
            scaleTargets[line] = (!inFocus && !reducedMotion) ? 97 : 100
            delays[line] = delay
            appearances[line] = appearance(line: line, isActive: isActive, inFocus: inFocus, lastActive: lastActive)

            screen += heights[line]
            natural += heights[line]
            if screen >= 0, mode != .quick, step > 0 {
                delay += step
                if line >= scrollIndex { step /= 1.05 }
            }
        }

        naturalTops = newTops
        followOffset = newFollow
        dots = newDots
        linesBottom = natural
        contentHeight = natural + viewport * (1 - Self.alignFraction)
        revision += 1
        refreshDots()

        for line in 0..<count {
            if mode == .snap || !hadLayout {
                offsetSprings[line].snap(to: 0)
                scaleSprings[line].snap(to: scaleTargets[line])
            } else {
                var shift = previousTops[line] - newTops[line]
                if followsScroll { shift += newFollow - currentOffset }
                offsetSprings[line].shiftCoordinates(by: shift)
                let quick = mode == .quick || reducedMotion
                offsetSprings[line].setParams(quick ? .quick : .position)
                scaleSprings[line].setParams(quick ? .quick : .scale)
                offsetSprings[line].retarget(0, delay: delays[line])
                scaleSprings[line].retarget(scaleTargets[line], delay: delays[line])
            }
            offsets[line] = offsetSprings[line].position
            scales[line] = scaleSprings[line].position / 100
        }
        hasLayout = true
        return followsScroll ? newFollow : nil
    }

    private func appearance(
        line: Int, isActive: Bool, inFocus: Bool, lastActive: Double
    ) -> LyricsLineAppearance {
        var blur = 0.0
        if blurEnabled, !reducedMotion, !inFocus {
            blur = 1
            if line < scrollIndex {
                blur += Double(abs(scrollIndex - line)) + 1
            } else {
                blur += abs(Double(line) - max(Double(scrollIndex), lastActive))
            }
            blur = min(32, blur * blurScale)
        }
        return LyricsLineAppearance(isActive: isActive, blur: blur)
    }

    private func refreshAppearance() {
        revision += 1
        let lastActive = activeIndex.map(Double.init) ?? -Double.infinity
        for line in 0..<timings.count {
            let isActive = line == activeIndex
            let inFocus = isActive || (Double(line) >= Double(scrollIndex) && Double(line) < lastActive)
            appearances[line] = appearance(
                line: line, isActive: isActive, inFocus: inFocus, lastActive: lastActive
            )
        }
    }

    // MARK: Interlude dots

    private func refreshDots() {
        guard dots.isVisible, let interlude else { return }
        let span = (interlude.end - interlude.start) * 1000
        let elapsed = max(0, (time - interlude.start) * 1000)
        guard elapsed <= span else {
            dots.scale = 0
            dots.opacities = [0, 0, 0]
            return
        }
        if reducedMotion {
            dots.scale = 0.7
            dots.opacities = [1, 1, 1]
            return
        }
        let breathe = span / (span / 1500).rounded(.up)
        var scale = sin(1.5 * Double.pi - elapsed / breathe * 2) / 20 + 1
        var alpha = 1.0
        if elapsed < 2000 { scale *= Self.easeOutExpo(elapsed / 2000) }
        if elapsed < 500 {
            alpha = 0
        } else if elapsed < 1000 {
            alpha *= (elapsed - 500) / 500
        }
        if span - elapsed < 750 {
            scale *= 1 - Self.easeInOutBack((750 - (span - elapsed)) / 750 / 2)
        }
        if span - elapsed < 375 { alpha *= Self.clamp(0, (span - elapsed) / 375, 1) }
        let fill = max(0, span - 750)
        dots.scale = max(0, scale) * 0.7
        dots.opacities = (0..<3).map { index in
            let progress = fill > 0 ? (elapsed - fill / 3 * Double(index)) * 3 / fill * 0.75 : 1
            return Self.clamp(0, max(0, alpha * Self.clamp(0.25, progress, 1)), 1)
        }
    }

    static func easeOutExpo(_ value: Double) -> Double {
        value == 1 ? 1 : 1 - pow(2, -10 * value)
    }

    static func easeInOutBack(_ value: Double) -> Double {
        let c = 2.5949095
        return value < 0.5
            ? pow(2 * value, 2) * ((c + 1) * 2 * value - c) / 2
            : (pow(2 * value - 2, 2) * ((c + 1) * (value * 2 - 2) + c) + 2) / 2
    }

    private static func clamp(_ low: Double, _ value: Double, _ high: Double) -> Double {
        max(low, min(value, high))
    }
}
