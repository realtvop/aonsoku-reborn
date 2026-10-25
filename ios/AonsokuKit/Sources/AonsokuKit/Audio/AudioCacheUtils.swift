import Foundation

enum AudioCacheUtils {
    static let appSupportSubdirectory = "Aonsoku"
    static let cacheDirectoryName = "AudioCache"

    static func cacheId(for songId: String) -> String {
        Data(songId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func cacheDirectoryURL(createIfNeeded: Bool) throws -> URL {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw AudioCacheError.directoryNotFound
        }

        let directory = documents
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
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/flac", "audio/x-flac":
            return "flac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a":
            return "m4a"
        case "audio/aac":
            return "aac"
        case "audio/ogg", "application/ogg":
            return "ogg"
        case "audio/opus":
            return "opus"
        case "audio/wav", "audio/x-wav":
            return "wav"
        default:
            return "audio"
        }
    }
}

enum AudioCacheError: Error {
    case directoryNotFound
}
