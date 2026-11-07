import AonsokuKit
import Perception
import SwiftUI
import UIKit

// The synced lyrics' view layer. `LyricsMotionEngine` (LyricsMotion.swift)
// decides where every line is and how it looks; this file draws the lines in
// a native scroll view and feeds the engine the playback clock every frame.

/// What one line shows. Position and size change every frame while it moves;
/// the appearance changes only when the current line does.
@MainActor
@Perceptible
final class LyricLineMotion {
    var top: CGFloat = 0
    var offset: CGFloat = 0
    var scale: CGFloat = 1
    var appearance = LyricsLineAppearance()
}

@MainActor
@Perceptible
final class LyricsDotsMotion {
    var state = LyricsDotsState()
}

@MainActor
@Perceptible
final class LyricsCanvasState {
    var contentHeight: CGFloat = 0
    var creditTop: CGFloat = 0
    /// Lines stay hidden until the first layout has placed the scroll view.
    var isReady = false
}

/// Connects the engine to the scroll view: measurements in, a clock tick
/// per frame, and the offset the engine asks for out.
@MainActor
final class LyricsMotionController {
    /// How long hand-scrolling holds the following back, as on the web.
    static let browseWindow: TimeInterval = 5
    /// How long blur stays off after a scroll ends, as on the web.
    static let blurResume: TimeInterval = 0.5

    let engine: LyricsMotionEngine
    let lines: [LyricLineMotion]
    let dots = LyricsDotsMotion()
    let canvas = LyricsCanvasState()

    private let position: () -> TimeInterval
    private weak var scroll: UIScrollView?
    private var link: ViewUpdateLink?
    private var isRunning = false
    private var lastTick: CFTimeInterval = 0
    private var lastTime: TimeInterval?
    private var seekRequested = false
    private var pendingOffset: Double?
    private var isInteracting = false
    private var lastManualScroll = -Double.infinity
    private var lastInteractionEnd = -Double.infinity
    private var heights: [Double]
    private var viewport = CGSize.zero
    private var dotsHeight = 0.0
    private var revision = -1
    private var measurePending = false

    init(lyrics: SongLyrics, position: @escaping () -> TimeInterval) {
        engine = LyricsMotionEngine(timings: lyrics.lines.map {
            LyricsLineTiming(start: $0.start, end: $0.end)
        })
        lines = lyrics.lines.map { _ in LyricLineMotion() }
        heights = Array(repeating: 0, count: lyrics.lines.count)
        self.position = position
    }

    // MARK: Inputs

    func attach(_ scroll: UIScrollView) {
        guard self.scroll !== scroll else { return }
        self.scroll = scroll
        let link = ViewUpdateLink(view: scroll) { [weak self] in self?.tick() }
        link.requiresContinuousUpdates = true
        link.isEnabled = isRunning
        self.link = link
        applyPendingOffset()
    }

    /// The page is visible: run every frame, starting from the right place.
    func setActive(_ active: Bool) {
        guard active != isRunning else { return }
        isRunning = active
        link?.isEnabled = active
        guard active else { return }
        lastTick = 0
        lastTime = nil
        lastManualScroll = -.infinity
        if let offset = engine.snapLayout(time: position()) { pendingOffset = offset }
        publish(all: true)
        applyPendingOffset()
    }

    func setReducedMotion(_ value: Bool) {
        engine.setReducedMotion(value)
        publish(all: true)
    }

    func setViewport(_ size: CGSize, dotsHeight: Double) {
        guard size != viewport || dotsHeight != self.dotsHeight else { return }
        viewport = size
        self.dotsHeight = dotsHeight
        scheduleMeasure()
    }

    func setHeight(_ height: CGFloat, at index: Int) {
        guard heights.indices.contains(index), heights[index] != Double(height) else { return }
        heights[index] = Double(height)
        scheduleMeasure()
    }

    /// A tap or other jump: lines move quickly and following resumes.
    func noteSeek() {
        seekRequested = true
        lastManualScroll = -.infinity
    }

    func scrollPhaseChanged(isUserDriven: Bool) {
        let now = CACurrentMediaTime()
        if isUserDriven {
            isInteracting = true
            pendingOffset = nil
            lastManualScroll = now
        } else if isInteracting {
            isInteracting = false
            lastInteractionEnd = now
            lastManualScroll = now
        }
    }

    // MARK: Frames

    private var isBrowsing: Bool {
        isInteracting || CACurrentMediaTime() - lastManualScroll < Self.browseWindow
    }

    private var currentOffset: Double {
        guard let scroll else { return engine.followOffset }
        return scroll.contentOffset.y + scroll.adjustedContentInset.top
    }

    /// Measurements arrive as many callbacks in a pass; lay out once.
    private func scheduleMeasure() {
        guard !measurePending else { return }
        measurePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            measurePending = false
            measure()
        }
    }

    private func measure() {
        guard viewport.height > 0, !heights.contains(0) || heights.isEmpty else { return }
        engine.blurScale = viewport.width <= 1_024 ? 0.8 : 1
        if !engine.isLaidOut {
            _ = engine.update(time: position(), seeking: true, followsScroll: true, currentOffset: 0)
        }
        if let offset = engine.setMeasurements(
            heights: heights, viewportHeight: Double(viewport.height), dotsHeight: dotsHeight,
            followsScroll: !isBrowsing
        ) {
            pendingOffset = offset
        }
        publish(all: true)
        applyPendingOffset()
        if pendingOffset == nil { canvas.isReady = true }
    }

    private func tick() {
        guard isRunning, engine.isLaidOut else { return }
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 0 : min(max(now - lastTick, 0), 0.05)
        lastTick = now
        let time = position()
        var seeking = seekRequested
        seekRequested = false
        // A jump in the clock is a seek, like the web's 500ms rule.
        if let lastTime, abs(time - lastTime) > 0.5 { seeking = true }
        lastTime = time
        if seeking, !isInteracting { lastManualScroll = -.infinity }

        engine.setBlurEnabled(!isInteracting && now - lastInteractionEnd > Self.blurResume)
        if let offset = engine.update(
            time: time, seeking: seeking, followsScroll: !isBrowsing, currentOffset: currentOffset
        ) {
            pendingOffset = offset
        }
        let moved = engine.advance(dt)
        publish(all: false, moved: moved)
        applyPendingOffset()
    }

    private func publish(all: Bool, moved: [Int] = []) {
        let layoutChanged = all || engine.revision != revision
        revision = engine.revision
        if layoutChanged {
            canvas.contentHeight = engine.contentHeight
            canvas.creditTop = engine.linesBottom + 12
            for index in lines.indices { update(index, full: true) }
        } else {
            for index in moved { update(index, full: false) }
        }
        if dots.state != engine.dots { dots.state = engine.dots }
    }

    private func update(_ index: Int, full: Bool) {
        let line = lines[index]
        let offset = CGFloat(engine.offsets[index])
        let scale = CGFloat(engine.scales[index])
        if line.offset != offset { line.offset = offset }
        if line.scale != scale { line.scale = scale }
        guard full else { return }
        let top = CGFloat(engine.naturalTops[index])
        if line.top != top { line.top = top }
        let appearance = engine.appearances[index]
        if line.appearance != appearance { line.appearance = appearance }
    }

    /// The scroll view's content size follows the canvas a layout pass
    /// later; moving it before then would be clamped.
    private func applyPendingOffset() {
        guard let target = pendingOffset, let scroll, !isInteracting else { return }
        guard target <= 0.5 || scroll.contentSize.height >= canvas.contentHeight - 1 else { return }
        pendingOffset = nil
        scroll.setContentOffset(
            CGPoint(x: 0, y: CGFloat(target) - scroll.adjustedContentInset.top), animated: false
        )
        canvas.isReady = true
    }
}

/// Sizes of one line's parts, from the web's `1.16em`/`.5em` rules.
struct LyricsTextMetrics: Equatable {
    let base: Double
    let main: CGFloat
    let sub: CGFloat
    let horizontal: CGFloat
    let vertical: CGFloat
    let dotDiameter: CGFloat
    let dotsHeight: Double

    init(size: CGSize, typeScale: CGFloat) {
        let width = Double(size.width)
        let height = Double(size.height)
        base = LyricsMetrics.baseSize(containerWidth: width, containerHeight: height) * Double(typeScale)
        main = LyricsMetrics.mainSize(base: base)
        sub = LyricsMetrics.subSize(base: base)
        horizontal = LyricsMetrics.horizontalPadding(width: width, base: base)
        vertical = LyricsMetrics.verticalPadding(base: base)
        dotDiameter = LyricsMetrics.dotDiameter(base: base, containerHeight: height)
        dotsHeight = LyricsMetrics.dotsHeight(base: base, width: width, containerHeight: height)
    }
}

private struct LyricsViewport: Equatable {
    let size: CGSize
    let dotsHeight: Double
}

// MARK: - Synced lyrics

struct SyncedLyrics: View {
    let lyrics: SongLyrics
    let showsTranslation: Bool
    let isActive: Bool
    let onControlsHiddenChange: (Bool) -> Void

    @Environment(PlayerStore.self) private var player
    @Environment(LyricsStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var typeScale: CGFloat = 1

    @State private var controller: LyricsMotionController?
    @State private var seekFeedback = 0

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { proxy in
                WithPerceptionTracking {
                    if let controller {
                        lyricsList(controller, size: proxy.size)
                    }
                }
            }
            .mask(EdgeFade())
            .haptic(.selection, trigger: seekFeedback)
            .onAppear { if controller == nil { makeController() } }
            .appOnChange(of: lyrics) { makeController() }
            .appOnChange(of: isActive) { controller?.setActive(isActive) }
            .appOnChange(of: reduceMotion) { controller?.setReducedMotion(reduceMotion) }
        }
    }

    private func makeController() {
        let next = LyricsMotionController(lyrics: lyrics) { [player, store] in
            player.clock.position() + store.selection.offset
        }
        next.setReducedMotion(reduceMotion)
        controller = next
        next.setActive(isActive)
    }

    private func lyricsList(_ controller: LyricsMotionController, size: CGSize) -> some View {
        let metrics = LyricsTextMetrics(size: size, typeScale: typeScale)
        return ScrollView {
            ZStack(alignment: .topLeading) {
                ForEach(lyrics.lines) { line in
                    LyricRow(
                        line: line, motion: controller.lines[line.id], metrics: metrics,
                        width: size.width, showsTranslation: showsTranslation,
                        reduceMotion: reduceMotion,
                        onHeight: { controller.setHeight($0, at: line.id) }
                    ) {
                        controller.noteSeek()
                        seekFeedback += 1
                        player.seek(to: max(line.start - store.selection.offset, 0))
                        if !player.isPlaying {
                            player.resume()
                        }
                    }
                }
                LyricsDotsView(motion: controller.dots, metrics: metrics)
                CreditRow(lyrics: lyrics, canvas: controller.canvas, width: size.width, metrics: metrics)
            }
            .frame(
                width: size.width, height: contentHeight(controller, viewport: size.height),
                alignment: .topLeading
            )
            .opacity(controller.canvas.isReady ? 1 : 0)
        }
        .id(ObjectIdentifier(controller))
        .scrollIndicators(.hidden)
        .background(LegacyScrollObserver(configure: { controller.attach($0) }))
        .modifier(LyricsControlsScrollObserver(
            isActive: isActive, onControlsHiddenChange: onControlsHiddenChange
        ))
        .appOnScrollPhaseChange { _, phase in
            controller.scrollPhaseChanged(isUserDriven: phase == .interacting || phase == .decelerating)
        }
        .appOnChange(of: LyricsViewport(size: size, dotsHeight: metrics.dotsHeight), initial: true) {
            controller.setViewport(size, dotsHeight: metrics.dotsHeight)
        }
    }

    private func contentHeight(_ controller: LyricsMotionController, viewport: CGFloat) -> CGFloat {
        // Until the first layout the content only has to exist.
        max(controller.canvas.contentHeight, viewport)
    }
}

/// Where a line is and how large. Kept apart from the row so that the springs,
/// which change these every frame, never rebuild the text.
private struct LyricPlacement: ViewModifier {
    let motion: LyricLineMotion

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .scaleEffect(motion.scale, anchor: .leading)
                .offset(y: motion.top + motion.offset)
        }
    }
}

/// One line: romanization above the original above the translation, in the
/// web player's hierarchy. Emphasis belongs to the original alone.
private struct LyricRow: View {
    let line: LyricLine
    let motion: LyricLineMotion
    let metrics: LyricsTextMetrics
    let width: CGFloat
    let showsTranslation: Bool
    let reduceMotion: Bool
    let onHeight: (CGFloat) -> Void
    let onTap: () -> Void

    var body: some View {
        WithPerceptionTracking {
            let appearance = motion.appearance
            Button(action: onTap) {
                texts(isActive: appearance.isActive)
                    .frame(width: width, alignment: .leading)
                    .contentShape(.rect)
                    .blur(radius: appearance.blur)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.2), value: appearance.blur
                    )
            }
            .buttonStyle(.touchFeedback)
            .appOnChange(of: measuredHeight, initial: true) { onHeight(measuredHeight) }
            .modifier(LyricPlacement(motion: motion))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(appearance.isActive ? .isSelected : [])
        }
    }

    private var original: String { line.text.isEmpty ? "♪" : line.text }
    private var romanization: String? {
        line.romanization.flatMap { $0.isEmpty ? nil : $0 }
    }
    private var translation: String? {
        guard showsTranslation else { return nil }
        return line.translation.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var textWidth: CGFloat { max(1, width - metrics.horizontal * 2) }

    private func layout(_ text: String, original: Bool = false) -> LyricsTextLayout {
        LyricsTextLayout(
            text: text,
            font: .systemFont(ofSize: original ? metrics.main : metrics.sub,
                              weight: original ? .semibold : .regular),
            width: textWidth,
            lineSpacing: original ? 0 : metrics.sub * 0.31
        )
    }

    private var measuredHeight: CGFloat {
        layout(original, original: true).height
            + (romanization.map { layout($0).height } ?? 0)
            + (translation.map { layout($0).height } ?? 0)
            + metrics.vertical * 2
    }

    private func text(_ value: String, original: Bool = false) -> some View {
        let layout = layout(value, original: original)
        return LyricsText(layout: layout)
            .frame(width: textWidth, height: layout.height, alignment: .topLeading)
    }

    /// Measure complete text at the focused font size. Emphasis is rendering
    /// only: it never changes wrapping or feeds transformed heights back in.
    private func texts(isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let romanization {
                text(romanization)
                    .opacity(0.3)
            }
            text(original, original: true)
                .scaleEffect(
                    isActive || reduceMotion ? 1 : LyricsMetrics.inactiveMainScale, anchor: .leading
                )
                .animation(
                    reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.42),
                    value: isActive
                )
                .opacity(isActive ? 0.85 : 0.2)
                .animation(
                    reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.3).delay(0.1),
                    value: isActive
                )
            if let translation {
                text(translation)
                    .opacity(0.3)
            }
        }
        .padding(.horizontal, metrics.horizontal)
        .padding(.vertical, metrics.vertical)
        .frame(width: width, height: measuredHeight, alignment: .topLeading)
    }
}

/// The three dots shown while a long instrumental plays.
private struct LyricsDotsView: View {
    let motion: LyricsDotsMotion
    let metrics: LyricsTextMetrics

    var body: some View {
        WithPerceptionTracking {
            let state = motion.state
            if state.isVisible {
                HStack(spacing: metrics.base * 0.25 + 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(.white)
                            .frame(width: metrics.dotDiameter, height: metrics.dotDiameter)
                            .opacity(state.opacities[index])
                    }
                }
                .padding(.horizontal, metrics.base * 0.75)
                .frame(height: metrics.dotsHeight, alignment: .center)
                .scaleEffect(state.scale)
                .offset(y: state.top)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct CreditRow: View {
    let lyrics: SongLyrics
    let canvas: LyricsCanvasState
    let width: CGFloat
    let metrics: LyricsTextMetrics

    var body: some View {
        WithPerceptionTracking {
            LyricsCredit(lyrics: lyrics)
                .padding(.horizontal, metrics.horizontal)
                .frame(width: width, alignment: .leading)
                .offset(y: canvas.creditTop)
        }
    }
}
