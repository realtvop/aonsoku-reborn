import AonsokuKit
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

    /// Nine colors for a 3×3 mesh, cycling through the palette and dimmed
    /// so white text stays legible on top.
    var meshColors: [Color] {
        guard !colors.isEmpty else { return Array(repeating: .black, count: 9) }
        let order = [0, 1, 2, 1, 0, 3, 2, 3, 0]
        return order.map { index in
            let color = colors[index % colors.count]
            let dimming = max(0, color.luminance - 0.35)
            return Color(
                RGBColor(
                    red: color.red * (1 - dimming),
                    green: color.green * (1 - dimming),
                    blue: color.blue * (1 - dimming)
                )
            )
        }
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
