import Foundation
import ImageIO

/// Provenance, not a guessed pixel threshold. Even a small server original is
/// the final source; numeric/unknown cache sizes are only previews for immersion.
enum CoverImageQuality {
    static let original = "original"

    static func isOriginal(_ size: String?) -> Bool { size == original }

    static func rank(_ size: String?) -> Int {
        if isOriginal(size) { return Int.max }
        return max(0, Int(size ?? "") ?? 0)
    }

    static func shouldReplace(cached: String?, incoming: String) -> Bool {
        rank(incoming) >= rank(cached)
    }

    static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func unrestrictedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.lastPathComponent == "getCoverArt" else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != "size" }
        return components.url ?? url
    }
}
