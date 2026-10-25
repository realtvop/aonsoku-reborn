import Foundation
import ImageIO
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

    /// WCAG contrast ratio with `other`, from 1 (none) to 21 (black on white).
    public func contrastRatio(with other: RGBColor) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Dominant colors of a cover, for Now Playing and detail backgrounds.
public struct ArtworkPalette: Hashable, Sendable {
    /// Up to four colors, most prominent first.
    public var colors: [RGBColor]
    /// Root-mean-square average, matching the web player's color extraction.
    public var average: RGBColor?
    /// The background is dark enough for light text.
    public var isDark: Bool

    public init(colors: [RGBColor], isDark: Bool, average: RGBColor? = nil) {
        self.colors = colors
        self.average = average
        self.isDark = isDark
    }
}

/// Decoded cover art and avatars. Serves memory first, then the native
/// cover cache, then downloads through `LibraryService` so every image is
/// cached for offline use. A larger cached size satisfies a smaller request.
public final class ArtworkProvider: @unchecked Sendable {
    public let library: LibraryService
    private let images = NSCache<NSString, UIImage>()
    private let state = ArtworkProviderState()
    private let coverLoader: @Sendable (String, ArtworkSize) async -> UIImage?
    private let paletteExtractor: @Sendable (UIImage) async -> ArtworkPalette?

    public convenience init(library: LibraryService) {
        self.init(
            library: library,
            coverLoader: { [library] id, size in
                await Self.loadCover(library: library, id: id, size: size)
            },
            paletteExtractor: { image in
                await Task.detached(priority: .utility) {
                    Self.extractPalette(from: image)
                }.value
            }
        )
    }

    convenience init(
        library: LibraryService,
        paletteExtractor: @escaping @Sendable (UIImage) async -> ArtworkPalette?
    ) {
        self.init(
            library: library,
            coverLoader: { [library] id, size in
                await Self.loadCover(library: library, id: id, size: size)
            },
            paletteExtractor: paletteExtractor
        )
    }

    init(
        library: LibraryService,
        coverLoader: @escaping @Sendable (String, ArtworkSize) async -> UIImage?,
        paletteExtractor: @escaping @Sendable (UIImage) async -> ArtworkPalette?
    ) {
        self.library = library
        self.coverLoader = coverLoader
        self.paletteExtractor = paletteExtractor
        images.countLimit = 160
    }

    /// A decoded image already in memory, for the first frame of a view.
    public func cachedImage(for coverArtId: String, size: ArtworkSize) -> UIImage? {
        cachedImage(prefix: "cover", id: coverArtId, size: size)
    }

    /// The largest smaller size already in memory, to show while `size`
    /// loads, so a cover a row or the mini player has shown does not
    /// flash a placeholder in Now Playing or a detail header.
    public func previewImage(for coverArtId: String, size: ArtworkSize) -> UIImage? {
        ArtworkSize.allCases
            .filter { $0.rawValue < size.rawValue }
            .sorted { $0.rawValue > $1.rawValue }
            .lazy
            .compactMap { self.images.object(
                forKey: self.cacheKey(prefix: "cover", id: coverArtId, size: $0) as NSString
            ) }
            .first
    }

    /// The decoded image, downloading it when needed. nil when unavailable.
    public func image(for coverArtId: String, size: ArtworkSize) async -> UIImage? {
        if let cached = cachedImage(for: coverArtId, size: size) { return cached }
        let key = cacheKey(prefix: "cover", id: coverArtId, size: size)
        let request = state.imageRequest(key: key) { [coverLoader] in
            await coverLoader(coverArtId, size)
        }
        let result = await request.task.value
        state.finishImageRequest(key: key, token: request.token)
        guard let result,
              state.storeImage(
                  result,
                  forKey: key,
                  generation: request.generation,
                  in: images
              ) else { return nil }
        return result
    }

    public func avatar(username: String, size: ArtworkSize = .small) async -> UIImage? {
        if let cached = cachedImage(prefix: "avatar", id: username, size: size) {
            return cached
        }
        let key = cacheKey(prefix: "avatar", id: username, size: size)
        let request = state.imageRequest(key: key) { [library] in
            guard let image = try? await library.downloadAvatar(
                username: username,
                size: size.requestValue
            ) else { return nil }
            return Self.downsample(image.uri, pixelSize: size.rawValue)
        }
        let result = await request.task.value
        state.finishImageRequest(key: key, token: request.token)
        guard let result,
              state.storeImage(
                  result,
                  forKey: key,
                  generation: request.generation,
                  in: images
              ) else { return nil }
        return result
    }

    /// Colors extracted from the medium cover, cached per id.
    public func palette(for coverArtId: String) async -> ArtworkPalette? {
        if let cached = state.palette(for: coverArtId) { return cached }
        let generation = state.currentGeneration()
        guard let image = await image(for: coverArtId, size: .medium),
              state.isCurrent(generation),
              let palette = await paletteExtractor(image),
              state.storePalette(
                  palette,
                  for: coverArtId,
                  generation: generation
              ) else {
            return nil
        }
        return palette
    }

    /// Drops decoded images, after covers are cleared or on memory warnings.
    public func purgeMemory() {
        state.purge(images: images)
    }

    private func cachedImage(
        prefix: String,
        id: String,
        size: ArtworkSize
    ) -> UIImage? {
        ArtworkSize.allCases
            .filter { $0.rawValue >= size.rawValue }
            .sorted { $0.rawValue < $1.rawValue }
            .lazy
            .compactMap { self.images.object(
                forKey: self.cacheKey(prefix: prefix, id: id, size: $0) as NSString
            ) }
            .first
    }

    private func cacheKey(prefix: String, id: String, size: ArtworkSize) -> String {
        "\(prefix):\(id):\(size.rawValue)"
    }

    private static func loadCover(
        library: LibraryService,
        id: String,
        size: ArtworkSize
    ) async -> UIImage? {
        var image: LibraryCachedImage?
        if let stored = library.coverSize(id: id) {
            let storedSize = stored.coverSize.flatMap(Int.init)
            if storedSize == nil || storedSize.map({ $0 >= size.rawValue }) == true {
                image = library.resolveCover(id: id, requestedSize: size.requestValue)
            }
        }
        if image == nil {
            image = try? await library.downloadCover(id: id, size: size.requestValue)
        }
        return image.flatMap { downsample($0.uri, pixelSize: size.rawValue) }
    }

    private static func downsample(_ location: String, pixelSize: Int) -> UIImage? {
        let url = URL(string: location) ?? URL(fileURLWithPath: location)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func extractPalette(from image: UIImage) -> ArtworkPalette? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        var buckets: [Int: ColorBucket] = [:]
        var squaredRed = 0.0
        var squaredGreen = 0.0
        var squaredBlue = 0.0
        var alphaWeight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            // CGContext provides premultiplied channels; undo premultiplication
            // before applying the web sqrt algorithm's alpha weighting.
            if alpha > 0 {
                let weight = Double(alpha) / 255
                squaredRed += pow(Double(pixels[index]) / Double(alpha), 2) * weight
                squaredGreen += pow(Double(pixels[index + 1]) / Double(alpha), 2) * weight
                squaredBlue += pow(Double(pixels[index + 2]) / Double(alpha), 2) * weight
                alphaWeight += weight
            }
            guard alpha >= 64 else { continue }
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            let key = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
            var bucket = buckets[key] ?? ColorBucket()
            bucket.count += 1
            bucket.red += red
            bucket.green += green
            bucket.blue += blue
            buckets[key] = bucket
        }

        let candidates = buckets.values
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
        guard !candidates.isEmpty else { return nil }

        var selected: [(RGBColor, Int)] = []
        for bucket in candidates {
            let color = bucket.color
            let distinct = selected.allSatisfy { existing in
                color.distanceSquared(to: existing.0) >= 0.025
            }
            if distinct { selected.append((color, bucket.count)) }
            if selected.count == 4 { break }
        }
        if selected.count < 4 {
            for bucket in candidates where selected.count < 4 {
                let color = bucket.color
                guard !selected.contains(where: { $0.0 == color }) else { continue }
                selected.append((color, bucket.count))
            }
        }

        let totalWeight = max(1, selected.reduce(0) { $0 + $1.1 })
        let luminance = selected.reduce(0.0) {
            $0 + $1.0.luminance * Double($1.1)
        } / Double(totalWeight)
        return ArtworkPalette(
            colors: selected.map(\.0),
            isDark: luminance < 0.45,
            average: alphaWeight > 0 ? RGBColor(
                red: sqrt(squaredRed / alphaWeight),
                green: sqrt(squaredGreen / alphaWeight),
                blue: sqrt(squaredBlue / alphaWeight)
            ) : nil
        )
    }
}

private struct ColorBucket {
    var count = 0
    var red = 0
    var green = 0
    var blue = 0

    var color: RGBColor {
        let divisor = Double(max(1, count) * 255)
        return RGBColor(
            red: Double(red) / divisor,
            green: Double(green) / divisor,
            blue: Double(blue) / divisor
        )
    }
}

private extension RGBColor {
    func distanceSquared(to other: RGBColor) -> Double {
        let red = red - other.red
        let green = green - other.green
        let blue = blue - other.blue
        return red * red + green * green + blue * blue
    }
}

private final class ArtworkProviderState: @unchecked Sendable {
    struct ImageRequest {
        let task: Task<UIImage?, Never>
        let token: UUID
        let generation: Int
    }

    private struct PendingImage {
        let task: Task<UIImage?, Never>
        let token: UUID
        let generation: Int
    }

    private let lock = NSLock()
    private var requests: [String: PendingImage] = [:]
    private var palettes: [String: ArtworkPalette] = [:]
    private var generation = 0

    func imageRequest(
        key: String,
        load: @escaping @Sendable () async -> UIImage?
    ) -> ImageRequest {
        lock.lock()
        defer { lock.unlock() }
        if let pending = requests[key] {
            return ImageRequest(
                task: pending.task,
                token: pending.token,
                generation: pending.generation
            )
        }
        let token = UUID()
        let task = Task.detached(priority: .utility) { await load() }
        let pending = PendingImage(task: task, token: token, generation: generation)
        requests[key] = pending
        return ImageRequest(task: task, token: token, generation: generation)
    }

    func finishImageRequest(key: String, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard requests[key]?.token == token else { return }
        requests.removeValue(forKey: key)
    }

    func isCurrent(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }

    func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func storeImage(
        _ image: UIImage,
        forKey key: String,
        generation expectedGeneration: Int,
        in images: NSCache<NSString, UIImage>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        images.setObject(image, forKey: key as NSString)
        return true
    }

    func palette(for id: String) -> ArtworkPalette? {
        lock.lock()
        defer { lock.unlock() }
        return palettes[id]
    }

    func storePalette(
        _ palette: ArtworkPalette,
        for id: String,
        generation expectedGeneration: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        palettes[id] = palette
        return true
    }

    func purge(images: NSCache<NSString, UIImage>) {
        lock.lock()
        generation += 1
        let tasks = requests.values.map(\.task)
        requests.removeAll()
        palettes.removeAll()
        images.removeAllObjects()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }
}
