import AonsokuKit
import Perception
import SwiftUI

extension Color {
    nonisolated init(_ rgb: RGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension ArtworkPalette {
    /// The cover's most prominent color.
    var dominant: Color? {
        colors.first.map(Color.init)
    }

    /// Text that reads on the dominant color.
    var foreground: Color {
        isDark ? .white : .black
    }
}

extension View {
    /// Extracts the palette of `coverArtId` into `palette`, animating the
    /// change; nil clears it.
    func artworkPalette(_ coverArtId: String?, into palette: Binding<ArtworkPalette?>) -> some View {
        modifier(ArtworkPaletteModifier(coverArtId: coverArtId, palette: palette))
    }
}

private struct ArtworkPaletteModifier: ViewModifier {
    let coverArtId: String?
    @Binding var palette: ArtworkPalette?

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content.task(id: coverArtId) {
                guard let coverArtId else {
                    palette = nil
                    return
                }
                let extracted = await app.artwork.palette(for: coverArtId)
                guard !Task.isCancelled, extracted != palette else { return }
                withAnimation(.smooth(duration: 0.6)) {
                    palette = extracted
                }
            }
        }
    }
}
