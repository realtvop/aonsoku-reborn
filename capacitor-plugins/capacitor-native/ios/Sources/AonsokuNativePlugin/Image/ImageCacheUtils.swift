import Foundation

enum ImageCacheUtils {
    static let appSupportSubdirectory = "Aonsoku"
    static let cacheDirectoryName = "ImageCache"
    static let cachedImageExtensions = ["jpg", "png", "webp", "gif"]

    static func cacheId(for coverArtId: String) -> String {
        Data(coverArtId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func cacheDirectoryURL(createIfNeeded: Bool) throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ImageCacheError.directoryNotFound
        }

        let directory = applicationSupport
            .appendingPathComponent(appSupportSubdirectory, isDirectory: true)
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)

        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var resourceURL = directory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? resourceURL.setResourceValues(resourceValues)
        }

        return directory
    }

    static func fileExtension(for contentType: String) -> String {
        let normalized = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch normalized {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "jpg"
        }
    }
}

enum ImageCacheError: Error {
    case directoryNotFound
    case invalidCoverArtId
    case noCredentials
    case invalidURL
    case downloadFailed(Error)
    case fileWriteFailed(Error)
}
