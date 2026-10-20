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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let fade: CGFloat = 12

    var body: some View {
        let scrolls = !reduceMotion && textWidth > availableWidth + 0.5
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
                    .offset(x: offset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask { edgeFade(isScrolling: offset != 0) }
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
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .task(id: ScrollKey(text: text, scrolls: scrolls, width: textWidth)) {
                await run(scrolls: scrolls)
            }
    }

    private func run(scrolls: Bool) async {
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

    /// Fades the trailing edge, and the leading edge while text moves
    /// under it.
    private func edgeFade(isScrolling: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: isScrolling ? fade : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
        }
        .animation(.easeInOut(duration: 0.3), value: isScrolling)
    }
}

private struct ScrollKey: Equatable {
    let text: String
    let scrolls: Bool
    let width: CGFloat
}
