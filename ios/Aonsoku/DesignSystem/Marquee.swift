import SwiftUI

/// One line of text that, when it does not fit, scrolls sideways after a
/// pause and starts over, like long titles in Apple Music's Now Playing.
/// The font and color come from the environment.
struct MarqueeText: View {
    let text: String
    /// Space between the end of the text and its repeat.
    var gap: CGFloat = 48
    /// Points per second.
    var speed: CGFloat = 32
    /// Seconds at rest before each pass.
    var pause: Double = 2.5
    /// Whether the system Reduce Motion setting disables scrolling.
    var respectsReduceMotion = true
    /// Inactive carousel pages stay at the beginning until they become current.
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let leadFade: CGFloat = 16
    private let trailFade: CGFloat = 24

    var body: some View {
        let allowsScrolling = !respectsReduceMotion || !reduceMotion
        let scrolls = allowsScrolling
            && availableWidth > 0
            && textWidth > availableWidth + 0.5
        let lead = scrolls ? min(leadFade, availableWidth / 4) : 0
        let trail = scrolls ? min(trailFade, availableWidth / 4) : 0

        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { availableWidth = $0 }
            .overlay(alignment: .leading) {
                if scrolls {
                    HStack(spacing: gap) {
                        Text(text)
                            .fixedSize()
                        Text(text)
                            .fixedSize()
                    }
                    .offset(x: (isActive ? offset : 0) + lead)
                    .frame(width: availableWidth + lead, alignment: .leading)
                    .offset(x: -lead)
                    .mask(alignment: .leading) {
                        edgeFade(lead: lead, trail: trail)
                            .frame(width: availableWidth + lead)
                    }
                } else {
                    Text(text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(alignment: .leading) {
                Text(text)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .task(id: ScrollKey(
                text: text,
                scrolls: scrolls,
                width: textWidth,
                isActive: isActive
            )) {
                await run(scrolls: scrolls && isActive)
            }
    }

    private func run(scrolls: Bool) async {
        defer { reset() }
        guard !Task.isCancelled else { return }
        reset()
        guard scrolls else { return }
        let distance = textWidth + gap
        let duration = Double(distance / speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) {
                offset = -distance
            }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // The repeat now sits where the text started, so the jump back
            // is invisible.
            reset()
        }
    }

    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
        }
    }

    /// Permanent leading and trailing edge fades. The leading fade sits in the
    /// overhang region to the left of the original text starting position, so
    /// stationary text is completely unmasked.
    private func edgeFade(lead: CGFloat, trail: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: lead)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: trail)
        }
    }
}

private struct ScrollKey: Equatable {
    let text: String
    let scrolls: Bool
    let width: CGFloat
    let isActive: Bool
}
