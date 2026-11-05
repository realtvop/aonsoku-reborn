import Foundation

/// What the desktop app's downloads hold, and what importing them would do.
public struct DesktopDownloadsSummary: Equatable, Sendable {
    /// Complete downloads found in the folder.
    public let songCount: Int
    public let totalBytes: Int64
    /// Songs an import changes something for: copied, or already here but not
    /// kept as downloads yet.
    public let importableCount: Int
    /// Bytes an import copies.
    public let importableBytes: Int64
    /// Metadata files that could not be used.
    public let skipped: Int
    /// Whether the user chose the folder (access lasts for this session).
    public let isPicked: Bool

    /// Every song found is a download on this Mac already.
    public var isUpToDate: Bool { songCount > 0 && importableCount == 0 }
}

/// Where "Import downloads from Aonsoku Desktop" stands in Settings → Storage.
public enum DesktopImportState: Equatable, Sendable {
    /// This platform has no desktop app (iOS): the row is not shown.
    case unavailable
    /// Not looked at yet.
    case idle
    case scanning
    case ready(DesktopDownloadsSummary)
    /// The folder is missing or this app may not read it: the user chooses it.
    case unreadable
    /// The folder is readable but holds no downloads.
    case empty(isPicked: Bool)
    case importing(DesktopImportProgress)
    case finished(DesktopImportResult)
    case failed(DesktopImportError)

    public var isBusy: Bool {
        switch self {
        case .scanning, .importing: return true
        default: return false
        }
    }
}
