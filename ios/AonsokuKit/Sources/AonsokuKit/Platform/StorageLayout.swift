import Foundation

/// Where AonsokuKit keeps its files. Every component that touches the disk
/// takes a layout (defaulting to `StorageLayout.current`), so the roots can be
/// redirected in tests and in unsandboxed development runs.
///
/// Two platform layouts exist and both are plain value computations over base
/// directories, so they can be pinned by tests on any host:
///
/// - **iOS** keeps the paths every existing install already uses:
///   `Application Support/Aonsoku/{Database,ImageCache,AudioCache,Tailscale}`
///   and downloads in `Documents/AudioCache`. These must never change.
/// - **macOS** keeps everything below `Application Support/github.realtvop.aonsoku`
///   and the purgeable image cache below `Caches/github.realtvop.aonsoku`, the
///   same sub-paths inside the sandbox container or outside it. It never lists
///   `Application Support/Aonsoku`, which is the Electron desktop app's
///   `userData` folder and may hold its downloads, and never `~/Documents`.
public struct StorageLayout: Equatable, Sendable {
    /// Directory name below `Application Support` on iOS (kept for existing
    /// installs).
    static let iOSDirectoryName = "Aonsoku"
    /// Directory name below `Application Support` and `Caches` on macOS. A
    /// constant rather than the bundle identifier: tests and other hosts of
    /// the package have identifiers of their own.
    static let macOSDirectoryName = "github.realtvop.aonsoku"

    /// Holds `library.sqlite` (library, cache index, preferences, playback and
    /// queue state).
    public let databaseDirectory: URL
    /// Cover art and avatars. Purgeable on macOS: a missing file is simply
    /// downloaded again.
    public let imageCacheDirectory: URL
    /// Where downloads and the copies made while streaming are written.
    public let audioCacheDirectory: URL
    /// The directories `NativeSourceResolver` searches for a cached song, in
    /// order.
    public let audioLookupDirectories: [URL]
    /// The directories `AudioService` resolves, deletes and clears audio
    /// files in, in order. Everything listed here may be emptied, so it holds
    /// only directories this app created.
    public let audioManagedDirectories: [URL]
    /// The embedded Tailscale node's state (iOS only in practice).
    public let tailscaleDirectory: URL

    public var databaseFileURL: URL {
        databaseDirectory.appendingPathComponent("library.sqlite", isDirectory: false)
    }

    // MARK: Platform layouts

    /// The iOS layout over the app's `Application Support` and `Documents`
    /// directories.
    ///
    /// - Parameter documents: nil only if the system reports no Documents
    ///   directory, which does not happen on iOS; downloads then use the
    ///   legacy directory.
    public static func iOS(applicationSupport: URL, documents: URL?) -> StorageLayout {
        let support = applicationSupport
            .appendingPathComponent(iOSDirectoryName, isDirectory: true)
        let legacyAudio = support.appendingPathComponent("AudioCache", isDirectory: true)
        let audio = documents?
            .appendingPathComponent("AudioCache", isDirectory: true) ?? legacyAudio
        // The two lists keep the orders the code had when each built its own:
        // playback looked in the legacy directory first, file management in
        // the current one.
        var lookup = [legacyAudio]
        if audio != legacyAudio { lookup.append(audio) }
        var managed = [audio]
        if legacyAudio != audio { managed.append(legacyAudio) }
        return StorageLayout(
            databaseDirectory: support.appendingPathComponent("Database", isDirectory: true),
            imageCacheDirectory: support.appendingPathComponent("ImageCache", isDirectory: true),
            audioCacheDirectory: audio,
            audioLookupDirectories: lookup,
            audioManagedDirectories: managed,
            tailscaleDirectory: support.appendingPathComponent("Tailscale", isDirectory: true)
        )
    }

    /// The macOS layout over the user's (or the container's) `Application
    /// Support` and `Caches` directories.
    public static func macOS(applicationSupport: URL, caches: URL) -> StorageLayout {
        let support = applicationSupport
            .appendingPathComponent(macOSDirectoryName, isDirectory: true)
        let cache = caches.appendingPathComponent(macOSDirectoryName, isDirectory: true)
        let audio = support.appendingPathComponent("AudioCache", isDirectory: true)
        return StorageLayout(
            databaseDirectory: support.appendingPathComponent("Database", isDirectory: true),
            imageCacheDirectory: cache.appendingPathComponent("ImageCache", isDirectory: true),
            audioCacheDirectory: audio,
            audioLookupDirectories: [audio],
            audioManagedDirectories: [audio],
            tailscaleDirectory: support.appendingPathComponent("Tailscale", isDirectory: true)
        )
    }

    /// The macOS layout with everything below one directory, for tests and
    /// scratch runs: `<root>/{Database,AudioCache,Tailscale}` and
    /// `<root>/Caches/ImageCache`.
    public static func macOS(root: URL) -> StorageLayout {
        let audio = root.appendingPathComponent("AudioCache", isDirectory: true)
        return StorageLayout(
            databaseDirectory: root.appendingPathComponent("Database", isDirectory: true),
            imageCacheDirectory: root
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("ImageCache", isDirectory: true),
            audioCacheDirectory: audio,
            audioLookupDirectories: [audio],
            audioManagedDirectories: [audio],
            tailscaleDirectory: root.appendingPathComponent("Tailscale", isDirectory: true)
        )
    }

    // MARK: Current

    /// The layout of this process, resolved once through `PlatformStorage`.
    public static var current: StorageLayout { PlatformStorage.current }
}

/// Resolves the layout of the running platform and answers which storage
/// features exist on it.
enum PlatformStorage {
    /// The one-time default layout. Tests (`swift test` on a Mac) get a
    /// throwaway directory, so that no singleton they touch can reach the
    /// real folders.
    static let current = makeDefault()

    /// Whether the Capacitor-era WebView data can exist on this platform. The
    /// former Capacitor app only ever shipped on iOS, so a Mac has none and
    /// must not open a WebView looking for it.
    static var supportsLegacyWebImport: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    /// Whether the Electron desktop app's downloads can be imported. They
    /// only exist on a Mac.
    static var supportsDesktopDownloadsImport: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The layout for `fileManager`'s directories. `environment` and
    /// `isTestProcess` only matter on macOS.
    static func makeDefault(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestProcess: Bool = isRunningUnderXCTest
    ) -> StorageLayout {
        let fallback = fileManager.temporaryDirectory
        let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fallback
        #if os(macOS)
        if let root = scratchRoot(environment: environment, isTestProcess: isTestProcess) {
            return .macOS(root: root)
        }
        let caches = fileManager.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? fallback
        return .macOS(applicationSupport: support, caches: caches)
        #else
        let documents = fileManager.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        return .iOS(applicationSupport: support, documents: documents)
        #endif
    }

    #if os(macOS)
    /// The environment variable that redirects every file the Kit writes
    /// below one directory. Honoured by debug builds only, so a stray
    /// variable cannot move a release build's data.
    static let dataRootVariable = "AONSOKU_DATA_ROOT"

    /// The directory used instead of the real locations, if any: the
    /// variable's value in a debug build, or a throwaway directory when the
    /// process hosts XCTest (in every configuration, so that no test run can
    /// reach the user's own folders, the Electron app's included).
    static func scratchRoot(
        environment: [String: String],
        isTestProcess: Bool
    ) -> URL? {
        #if DEBUG
        if let path = environment[dataRootVariable], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        guard isTestProcess else { return nil }
        return TestProcessScratch.directory
    }

    /// One directory per test process, removed when the process exits.
    private enum TestProcessScratch {
        static let directory: URL = {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "aonsoku-kit-data-\(getpid())",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
            scratchPathForExit = url.path
            atexit {
                if let path = scratchPathForExit {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            return url
        }()
    }
    #endif

    /// Whether XCTest has loaded into this process.
    static var isRunningUnderXCTest: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

#if os(macOS)
/// Read by the exit handler, which cannot capture state.
nonisolated(unsafe) private var scratchPathForExit: String?
#endif
