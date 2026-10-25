import SwiftUI

/// The Aonsoku mark, four nested rings, drawn from the web
/// `public/icon_transparent.svg` so it stays sharp at any size.
struct AonsokuMark: View {
    var color = AonsokuMark.green

    static let green = Color(red: 0x20 / 255, green: 0xB3 / 255, blue: 0x58 / 255)

    /// Center x, center y and radius of each ring in the SVG's 1024-point
    /// view box.
    private static let rings: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
        (512, 512, 357.815),
        (542.446, 513.243, 301.272),
        (573.514, 515.728, 245.349),
        (604.582, 513.864, 189.427),
    ]

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 1024
            for ring in Self.rings {
                let rect = CGRect(
                    x: (ring.x - ring.radius) * scale,
                    y: (ring.y - ring.radius) * scale,
                    width: ring.radius * 2 * scale,
                    height: ring.radius * 2 * scale
                )
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 30 * scale)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
