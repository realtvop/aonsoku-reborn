import Foundation
#if os(macOS)
import Darwin
#endif

/// Where the Electron desktop app (Aonsoku Desktop) keeps its downloads.
///
/// The folder is only ever read: nothing in AonsokuKit creates, changes,
/// moves or deletes anything below `directory`.
public struct DesktopDataLocation: Equatable, Sendable {
    /// The desktop app's `userData` folder, or the folder that contains the
    /// picked `AudioCache`.
    public let directory: URL
    /// The folder holding `<base64url(songId)>.<ext>` and
    /// `<base64url(songId)>.json` pairs.
    public let audioCacheDirectory: URL
    /// Whether the user chose the folder in an open panel (access then lasts
    /// for this session only) rather than it being found automatically.
    public let isPicked: Bool
    /// The URL the open panel granted access to: what to start and stop
    /// accessing, which is the picked folder itself.
    let accessURL: URL

    public init(
        directory: URL,
        audioCacheDirectory: URL,
        isPicked: Bool = false,
        accessURL: URL? = nil
    ) {
        self.directory = directory
        self.audioCacheDirectory = audioCacheDirectory
        self.isPicked = isPicked
        self.accessURL = accessURL ?? directory
    }
}

/// Finds the Electron desktop app's data on a Mac. Every other platform has
/// none, so the answers are nil there and the import is never offered.
public enum DesktopDataLocator {
    /// Electron's `userData` folder name below `Application Support`
    /// (`app.getPath("userData")` for the app named "Aonsoku").
    static let userDataDirectoryName = "Aonsoku"
    /// Its download folder (`audioCacheDirectoryFromUserDataPath`).
    static let audioCacheDirectoryName = "AudioCache"

    /// The debug-only variable that points the import at a scratch copy of
    /// the desktop app's folder instead of the real one.
    static let overrideVariable = "AONSOKU_DESKTOP_DATA"

    /// Whether this platform can have desktop downloads to import.
    public static var isSupported: Bool {
        PlatformStorage.supportsDesktopDownloadsImport
    }

    /// The user's real home directory, from the account database. In a
    /// sandboxed app `NSHomeDirectory()` is the container, which is not where
    /// the desktop app wrote its data.
    static func realHomeDirectory() -> URL? {
        #if os(macOS)
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        #else
        return nil
        #endif
    }

    /// `~/Library/Application Support` of the real user: where an open panel
    /// should start, since the desktop app's folder is below it.
    public static var applicationSupportDirectory: URL? {
        realHomeDirectory()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// The place to look without asking: the desktop app's own folder.
    ///
    /// A sandboxed app cannot read it, so a scan there fails with
    /// `DesktopImportError.sourceUnreadable` and the user picks the folder.
    public static func defaultLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DesktopDataLocation? {
        guard isSupported else { return nil }
        #if DEBUG
        if let path = environment[overrideVariable], !path.isEmpty {
            return location(
                forDirectory: URL(fileURLWithPath: path, isDirectory: true),
                isPicked: false
            )
        }
        #endif
        guard let support = applicationSupportDirectory else { return nil }
        return location(
            forDirectory: support.appendingPathComponent(
                userDataDirectoryName, isDirectory: true
            ),
            isPicked: false
        )
    }

    /// What a folder chosen in an open panel means: the desktop app's data
    /// folder, or its `AudioCache` itself.
    public static func location(forPicked url: URL) -> DesktopDataLocation? {
        guard isSupported else { return nil }
        let picked = url.standardizedFileURL
        if picked.lastPathComponent == audioCacheDirectoryName {
            return DesktopDataLocation(
                directory: picked.deletingLastPathComponent(),
                audioCacheDirectory: picked,
                isPicked: true,
                accessURL: picked
            )
        }
        return location(forDirectory: picked, isPicked: true)
    }

    static func location(forDirectory directory: URL, isPicked: Bool) -> DesktopDataLocation {
        DesktopDataLocation(
            directory: directory,
            audioCacheDirectory: directory.appendingPathComponent(
                audioCacheDirectoryName, isDirectory: true
            ),
            isPicked: isPicked
        )
    }
}
