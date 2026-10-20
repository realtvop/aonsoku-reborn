import Foundation
import UIKit

/// Cover sizes requested from the server, in pixels.
public enum ArtworkSize: Int, Sendable, CaseIterable {
    /// Rows and grid thumbnails on compact screens.
    case small = 150
    /// Grid cells and the mini player.
    case medium = 300
    /// Detail headers and Now Playing.
    case large = 700

    public var requestValue: String { String(rawValue) }
}

/// An sRGB color with components in 0...1.
public struct RGBColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Relative luminance, 0...1.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// Dominant colors of a cover, for Now Playing and detail backgrounds.
public struct ArtworkPalette: Hashable, Sendable {
    /// Four colors, most prominent first, for a mesh gradient.
    public var colors: [RGBColor]
    /// The background is dark enough for light text.
    public var isDark: Bool

    public init(colors: [RGBColor], isDark: Bool) {
        self.colors = colors
        self.isDark = isDark
    }
}

/// Decoded cover art and avatars. Serves memory first, then the native
/// cover cache, then downloads through `LibraryService` so every image is
/// cached for offline use. A larger cached size satisfies a smaller request.
public final class ArtworkProvider: @unchecked Sendable {
    public let library: LibraryService

    public init(library: LibraryService) {
        self.library = library
    }

    /// A decoded image already in memory, for the first frame of a view.
    public func cachedImage(for coverArtId: String, size: ArtworkSize) -> UIImage? { nil }

    /// The decoded image, downloading it when needed. nil when unavailable.
    public func image(for coverArtId: String, size: ArtworkSize) async -> UIImage? { nil }

    public func avatar(username: String, size: ArtworkSize = .small) async -> UIImage? { nil }

    /// Colors extracted from the medium cover, cached per id.
    public func palette(for coverArtId: String) async -> ArtworkPalette? { nil }

    /// Drops decoded images, after covers are cleared or on memory warnings.
    public func purgeMemory() {}
}
