import CoreGraphics
import Foundation

@main
enum LyricsMotionTests {
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6, _ message: String) {
        precondition(abs(a - b) <= tolerance, "\(message): \(a) != \(b)")
    }

    static func main() {
        springsMatchAMLL()
        metrics()
        introAndInterlude()
        followingStaggersAndBlurs()
        browsingAndResuming()
        seekingAndReducedMotion()
        print("Lyrics motion tests passed")
    }

    // MARK: Springs

    /// Reference values come from AMLL's own `Tt` spring class
    /// (`@applemusic-like-lyrics/core` 0.2.0), stepped with the same
    /// sequence of calls.
    static func springsMatchAMLL() {
        func run(
            _ params: LyricsSpringParams, start: Double = 0,
            _ steps: [(target: Double?, delay: Double, dt: Double?)]
        ) -> [Double] {
            var spring = LyricsSpring(start, params: params)
            var result: [Double] = []
            for step in steps {
                if let target = step.target { spring.retarget(target, delay: step.delay) }
                if let dt = step.dt {
                    spring.advance(dt)
                    result.append(spring.position)
                }
            }
            return result
        }

        let a = run(.position, [(100, 0, nil)] + Array(repeating: (nil, 0, 0.1), count: 10))
        let expectedA = [
            28.612389022425447, 66.07860405380349, 88.39003918289745, 97.81846030881538,
            100.57904524762624, 100.84038811106619, 100.51230924366162, 100.22025174385332,
            100.0661684208348, 100.00734788154504,
        ]
        for (index, value) in expectedA.enumerated() {
            near(a[index], value, 1e-9, "Position spring at step \(index)")
        }

        // Retargeting in flight keeps the velocity.
        let b = run(.position, [
            (100, 0, nil), (nil, 0, 0.1), (nil, 0, 0.1), (0, 0, nil),
            (nil, 0, 0.1), (nil, 0, 0.1), (nil, 0, 0.1), (nil, 0, 0.1), (nil, 0, 0.1),
        ])
        let expectedB = [
            28.612389022425447, 66.07860405380349, 59.77763469515492, 31.73984481454986,
            12.189000522672748, 3.021925863341267, -0.06673639151299675,
        ]
        for (index, value) in expectedB.enumerated() {
            // AMLL differentiates numerically, which costs a few digits.
            near(b[index], value, 1e-4, "Retargeted spring at step \(index)")
        }

        // A delayed target keeps the line where it is until the delay ends.
        var delayed = LyricsSpring(50, params: .position)
        delayed.retarget(0, delay: 0.25)
        var c: [Double] = []
        for _ in 0..<6 {
            delayed.advance(0.1)
            c.append(delayed.position)
        }
        let expectedC = [50, 50, 50, 35.69380548878728, 16.960697973098256, 5.804980408551277]
        for (index, value) in expectedC.enumerated() {
            near(c[index], value, 1e-4, "Delayed spring at step \(index)")
        }

        let d = run(.scale, start: 100, [(97, 0, nil)] + Array(repeating: (nil, 0, 0.1), count: 8))
        let expectedD = [
            99.50418535533126, 98.67599908183848, 97.97950522133227, 97.5115773517752,
            97.2373443948954, 97.0937442798972, 97.02691674158001, 97.00039529229909,
        ]
        for (index, value) in expectedD.enumerated() {
            near(d[index], value, 1e-9, "Scale spring at step \(index)")
        }

        var shifted = LyricsSpring(0, params: .position)
        shifted.shiftCoordinates(by: 40)
        precondition(shifted.position == 40 && shifted.target == 40, "Shifting moves value and target")
        shifted.retarget(0)
        for _ in 0..<400 { shifted.advance(1.0 / 60) }
        precondition(shifted.position == 0 && shifted.isSettled, "A spring comes to rest on its target")
    }

    // MARK: Metrics

    static func metrics() {
        let base = LyricsMetrics.baseSize(containerWidth: 390, containerHeight: 844)
        near(base, 31.2, 1e-9, "Phones use 8vw")
        near(LyricsMetrics.mainSize(base: base), 36.192, 1e-9, "Focused original is 1.16em")
        near(
            LyricsMetrics.mainSize(base: base) * LyricsMetrics.inactiveMainScale, base, 1e-3,
            "An unfocused original is exactly one em"
        )
        near(LyricsMetrics.subSize(base: base), 15.6, 1e-9, "Translation and romanization are half an em")
        precondition(LyricsMetrics.subSize(base: 12) == 10, "Never below 10pt")
        precondition(LyricsMetrics.baseSize(containerWidth: 100, containerHeight: 400) == 12, "Never below 12pt")
        precondition(LyricsMetrics.horizontalPadding(width: 390, base: base) == 20)
        near(LyricsMetrics.horizontalPadding(width: 600, base: 31), 31, 1e-9, "Wider lines pad by one em")
        near(LyricsMetrics.dotDiameter(base: base, containerHeight: 844), 15.6, 1e-9, "Dots are half an em at least")
        near(LyricsMetrics.dotsHeight(base: base, width: 390, containerHeight: 844), 35.1, 1e-9, "Dots slot height")
        precondition(LyricsMetrics.baseSize(containerWidth: 1_024, containerHeight: 1_366) == 40, "Tablets are capped")

        near(LyricsMotionEngine.easeOutExpo(1), 1, 1e-12, "easeOutExpo end")
        near(LyricsMotionEngine.easeInOutBack(0), 0, 1e-9, "easeInOutBack start")
        near(LyricsMotionEngine.easeInOutBack(0.5), 0.5, 1e-9, "easeInOutBack middle")
    }

    // MARK: Engine fixtures

    static let heights = Array(repeating: 100.0, count: 6)

    /// Six lines of four seconds each, the first starting at ten seconds.
    static func makeEngine() -> LyricsMotionEngine {
        let timings = (0..<6).map { index in
            LyricsLineTiming(start: 10 + Double(index) * 4, end: 14 + Double(index) * 4)
        }
        let engine = LyricsMotionEngine(timings: timings)
        return engine
    }

    static func lay(_ engine: LyricsMotionEngine, at time: Double) -> Double? {
        _ = engine.update(time: time, seeking: true, followsScroll: true, currentOffset: 0)
        return engine.setMeasurements(
            heights: heights, viewportHeight: 600, dotsHeight: 40, followsScroll: true
        )
    }

    static func settle(_ engine: LyricsMotionEngine, seconds: Double = 4) {
        for _ in 0..<Int(seconds * 60) { _ = engine.advance(1.0 / 60) }
    }

    // MARK: Interlude

    static func introAndInterlude() {
        let engine = makeEngine()
        let offset = lay(engine, at: 0)
        precondition(offset == 0, "The intro sits at the top")
        precondition(engine.dots.isVisible, "Nine seconds of silence show the dots")
        near(engine.dots.top, 210, 1e-9, "Dots start at 35% of the viewport")
        near(engine.naturalTops[0], 250, 1e-9, "The first line follows the dots' slot")
        near(engine.naturalTops[1], 350, 1e-9, "Later lines follow the slot too")
        near(engine.contentHeight, 210 + 40 + 600 + 390, 1e-9, "Content covers the slot, the lines and the tail")
        near(engine.dots.opacities[0], 0, 1e-9, "Dots start hidden")

        _ = engine.update(time: 4, seeking: false, followsScroll: true, currentOffset: 0)
        precondition(engine.dots.scale > 0 && engine.dots.scale <= 0.8, "Dots breathe")
        precondition(engine.dots.opacities.allSatisfy { $0 >= 0 && $0 <= 1 && !$0.isNaN }, "Dot opacities stay in range")
        precondition(engine.dots.opacities[0] >= engine.dots.opacities[2], "Dots fill in order")

        _ = engine.update(time: 8.6, seeking: false, followsScroll: true, currentOffset: 0)
        precondition(engine.dots.opacities[0] < 0.5 && engine.dots.scale < 0.7, "Dots leave before the first line")

        // The first line starts a second early and takes the slot's space.
        let next = engine.update(time: 9.5, seeking: false, followsScroll: true, currentOffset: 0)
        precondition(next == 0, "Aligned to the first line")
        precondition(!engine.dots.isVisible, "The dots go when the line starts")
        near(engine.naturalTops[0], 210, 1e-9, "The first line moves up into the dots' space")
        near(engine.offsets[0], 40, 1e-9, "…springing from where it was")
        near(engine.offsets[5], 40, 1e-9, "…as does every line below")
        settle(engine)
        for index in 0..<6 { near(engine.offsets[index], 0, 1e-9, "Line \(index) settled") }

        // Tiny gaps never show dots.
        let short = LyricsMotionEngine(timings: [
            LyricsLineTiming(start: 2, end: 6), LyricsLineTiming(start: 6, end: 9),
        ])
        _ = short.update(time: 0, seeking: true, followsScroll: true, currentOffset: 0)
        _ = short.setMeasurements(heights: [100, 100], viewportHeight: 600, dotsHeight: 40, followsScroll: true)
        precondition(!short.dots.isVisible, "A short intro has no dots")
    }

    // MARK: Following

    static func followingStaggersAndBlurs() {
        let engine = makeEngine()
        _ = lay(engine, at: 19)
        precondition(engine.appearances[2].isActive && !engine.appearances[1].isActive)
        near(engine.followOffset, 200, 1e-9, "Offset aligns the current line's top to 35%")
        near(engine.naturalTops[2] - engine.followOffset, 210, 1e-9, "The current line sits at 35% of the viewport")
        for (index, expected) in [3.2, 2.4, 0, 1.6, 2.4, 3.2].enumerated() {
            near(engine.appearances[index].blur, expected, 1e-9, "Blur of line \(index)")
        }
        near(engine.scales[2], 1, 1e-9, "The current line is full size")
        near(engine.scales[1], 0.97, 1e-9, "Others shrink a little")

        // Next line: one step forward.
        let offset = engine.update(time: 22.5, seeking: false, followsScroll: true, currentOffset: 200)
        precondition(offset == 300, "Following moves a line's height")
        for index in 0..<6 { near(engine.offsets[index], 100, 1e-9, "Line \(index) stays on screen at first") }
        _ = engine.advance(0.04)
        precondition(engine.offsets[0] < 100, "The first line starts at once")
        precondition(engine.offsets[3] == 100, "Each later line waits its turn")
        for _ in 0..<10 { _ = engine.advance(0.016) }
        precondition(engine.offsets[3] < 100, "…then follows")
        precondition(engine.offsets[5] == 100, "The last line waits the longest")
        for _ in 0..<10 { _ = engine.advance(0.016) }
        precondition(engine.offsets[5] < 100, "…and follows last")
        precondition(engine.offsets[0] < engine.offsets[3] && engine.offsets[3] < engine.offsets[5], "Staggered")
        settle(engine)
        for index in 0..<6 { near(engine.offsets[index], 0, 1e-9, "Line \(index) came to rest") }
        near(engine.scales[3], 1, 1e-9, "The new current line grew")
        near(engine.scales[2], 0.97, 1e-9, "…and the old one shrank")
    }

    // MARK: Browsing

    static func browsingAndResuming() {
        let engine = makeEngine()
        _ = lay(engine, at: 19)
        // Browsing: the layout holds still while the song moves on.
        let held = engine.update(time: 23, seeking: false, followsScroll: false, currentOffset: 520)
        precondition(held == nil, "Browsing never moves the scroll view")
        precondition(engine.appearances[3].isActive, "The current line still changes")
        for index in 0..<6 { precondition(engine.offsets[index] == 0, "Line \(index) holds still") }
        near(engine.followOffset, 300, 1e-9, "…but the follow position is known")

        // Following again: lines keep their place on screen, then spring.
        let resumed = engine.update(time: 27, seeking: false, followsScroll: true, currentOffset: 520)
        precondition(resumed == 400)
        for index in 0..<6 { near(engine.offsets[index], 400 - 520, 1e-9, "Line \(index) keeps its place") }
        settle(engine)
        for index in 0..<6 { near(engine.offsets[index], 0, 1e-9, "Line \(index) returned") }

        // A smaller viewport while browsing keeps the layout, but not the scroll range.
        let before = engine.naturalTops
        let rangeBefore = engine.contentHeight
        let none = engine.setMeasurements(heights: heights, viewportHeight: 700, dotsHeight: 40, followsScroll: false)
        precondition(none == nil && engine.naturalTops == before, "Browsing ignores viewport changes")
        precondition(engine.contentHeight != rangeBefore, "…except for the scroll range")
    }

    // MARK: Seeking

    static func seekingAndReducedMotion() {
        let engine = makeEngine()
        _ = lay(engine, at: 12)
        let target = engine.update(time: 31, seeking: true, followsScroll: true, currentOffset: 0)
        precondition(target == 500, "A seek aligns to the new line")
        _ = engine.advance(0.016)
        for index in 0..<6 {
            precondition(engine.offsets[index] < 500, "Line \(index) moves at once after a seek")
        }
        settle(engine, seconds: 2)
        for index in 0..<6 { near(engine.offsets[index], 0, 1e-9, "Line \(index) settled after a seek") }

        let still = makeEngine()
        still.reducedMotion = true
        _ = lay(still, at: 19)
        precondition(still.appearances.allSatisfy { $0.blur == 0 }, "No blur with Reduce Motion")
        precondition(still.scales.allSatisfy { $0 == 1 }, "No shrinking with Reduce Motion")
        _ = still.update(time: 23, seeking: false, followsScroll: true, currentOffset: 200)
        _ = still.advance(0.016)
        precondition(still.offsets[0] < 100 && still.offsets[5] < 100, "Everything moves together")

        let plain = makeEngine()
        plain.blurEnabled = false
        _ = lay(plain, at: 19)
        precondition(plain.appearances.allSatisfy { $0.blur == 0 }, "Blur can be turned off while scrolling")
        plain.setBlurEnabled(true)
        near(plain.appearances[0].blur, 3.2, 1e-9, "…and back on")
    }
}
