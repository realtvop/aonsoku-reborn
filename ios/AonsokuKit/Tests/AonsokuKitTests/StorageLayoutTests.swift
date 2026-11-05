import XCTest

@testable import AonsokuKit

/// Pins where AonsokuKit keeps its files: the iOS paths every existing install
/// uses must never change, and the macOS layout must stay clear of the
/// Electron app's `userData` folder and of `~/Documents`.
@MainActor
final class StorageLayoutTests: XCTestCase {
    // MARK: iOS pins (computed on any host)

    private let iosContainer = "/var/mobile/Containers/Data/Application/ABCDEF"

    private func iosLayout() -> StorageLayout {
        StorageLayout.iOS(
            applicationSupport: URL(
                fileURLWithPath: "\(iosContainer)/Library/Application Support",
                isDirectory: true
            ),
            documents: URL(fileURLWithPath: "\(iosContainer)/Documents", isDirectory: true)
        )
    }

    func testIOSLayoutKeepsEveryPathExistingInstallsUse() {
        let layout = iosLayout()
        let support = "\(iosContainer)/Library/Application Support/Aonsoku"

        XCTAssertEqual(layout.databaseDirectory.path, "\(support)/Database")
        XCTAssertEqual(layout.databaseFileURL.path, "\(support)/Database/library.sqlite")
        XCTAssertEqual(layout.imageCacheDirectory.path, "\(support)/ImageCache")
        XCTAssertEqual(layout.audioCacheDirectory.path, "\(iosContainer)/Documents/AudioCache")
        XCTAssertEqual(layout.tailscaleDirectory.path, "\(support)/Tailscale")
    }

    func testIOSAudioDirectoryListsKeepTheirOrder() {
        let layout = iosLayout()
        let legacy = "\(iosContainer)/Library/Application Support/Aonsoku/AudioCache"
        let current = "\(iosContainer)/Documents/AudioCache"

        // Playback looked in the legacy directory first, file management in
        // the current one first: both orders existed before the layout did.
        XCTAssertEqual(layout.audioLookupDirectories.map(\.path), [legacy, current])
        XCTAssertEqual(layout.audioManagedDirectories.map(\.path), [current, legacy])
    }

    func testIOSLayoutWithoutADocumentsDirectoryUsesTheLegacyOne() {
        let layout = StorageLayout.iOS(
            applicationSupport: URL(
                fileURLWithPath: "\(iosContainer)/Library/Application Support",
                isDirectory: true
            ),
            documents: nil
        )
        let legacy = "\(iosContainer)/Library/Application Support/Aonsoku/AudioCache"

        XCTAssertEqual(layout.audioCacheDirectory.path, legacy)
        XCTAssertEqual(layout.audioLookupDirectories.map(\.path), [legacy])
        XCTAssertEqual(layout.audioManagedDirectories.map(\.path), [legacy])
    }

    #if os(iOS)
    func testTheIOSDefaultIsTheIOSLayoutOfTheRealDirectories() throws {
        let support = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first)
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        XCTAssertEqual(
            StorageLayout.current,
            StorageLayout.iOS(applicationSupport: support, documents: documents)
        )
    }
    #endif

    // MARK: macOS layout (computed on any host)

    private let sandboxedSupport = "/Users/u/Library/Containers/github.realtvop.aonsoku/Data/Library/Application Support"
    private let sandboxedCaches = "/Users/u/Library/Containers/github.realtvop.aonsoku/Data/Library/Caches"
    private let plainSupport = "/Users/u/Library/Application Support"
    private let plainCaches = "/Users/u/Library/Caches"

    private func macLayout(support: String, caches: String) -> StorageLayout {
        StorageLayout.macOS(
            applicationSupport: URL(fileURLWithPath: support, isDirectory: true),
            caches: URL(fileURLWithPath: caches, isDirectory: true)
        )
    }

    func testMacLayoutKeepsEverythingBelowTheAppsOwnDirectories() {
        let layout = macLayout(support: plainSupport, caches: plainCaches)
        let own = "\(plainSupport)/github.realtvop.aonsoku"

        XCTAssertEqual(layout.databaseDirectory.path, "\(own)/Database")
        XCTAssertEqual(layout.databaseFileURL.path, "\(own)/Database/library.sqlite")
        XCTAssertEqual(layout.audioCacheDirectory.path, "\(own)/AudioCache")
        XCTAssertEqual(layout.tailscaleDirectory.path, "\(own)/Tailscale")
        // Purgeable data goes to Caches.
        XCTAssertEqual(
            layout.imageCacheDirectory.path,
            "\(plainCaches)/github.realtvop.aonsoku/ImageCache"
        )
        XCTAssertEqual(layout.audioLookupDirectories.map(\.path), ["\(own)/AudioCache"])
        XCTAssertEqual(layout.audioManagedDirectories.map(\.path), ["\(own)/AudioCache"])
    }

    func testMacLayoutHasTheSameSubpathsSandboxedOrNot() {
        let sandboxed = macLayout(support: sandboxedSupport, caches: sandboxedCaches)
        let plain = macLayout(support: plainSupport, caches: plainCaches)

        func relative(_ url: URL, to base: String) -> String {
            url.path.replacingOccurrences(of: base, with: "")
        }
        XCTAssertEqual(
            relative(sandboxed.databaseFileURL, to: sandboxedSupport),
            relative(plain.databaseFileURL, to: plainSupport)
        )
        XCTAssertEqual(
            relative(sandboxed.audioCacheDirectory, to: sandboxedSupport),
            relative(plain.audioCacheDirectory, to: plainSupport)
        )
        XCTAssertEqual(
            relative(sandboxed.tailscaleDirectory, to: sandboxedSupport),
            relative(plain.tailscaleDirectory, to: plainSupport)
        )
        XCTAssertEqual(
            relative(sandboxed.imageCacheDirectory, to: sandboxedCaches),
            relative(plain.imageCacheDirectory, to: plainCaches)
        )
    }

    func testMacLayoutNeverReachesElectronsFolderOrDocuments() {
        let layout = macLayout(support: plainSupport, caches: plainCaches)
        let electron = "\(plainSupport)/Aonsoku"
        let documents = "/Users/u/Documents"
        let directories = [
            layout.databaseDirectory, layout.imageCacheDirectory,
            layout.audioCacheDirectory, layout.tailscaleDirectory,
        ] + layout.audioLookupDirectories + layout.audioManagedDirectories

        for directory in directories {
            // A path equal to, or below, Electron's userData or Documents.
            XCTAssertFalse(
                (directory.path + "/").hasPrefix(electron + "/"),
                "\(directory.path) is inside Electron's userData folder"
            )
            XCTAssertFalse(
                (directory.path + "/").hasPrefix(documents + "/"),
                "\(directory.path) is inside Documents"
            )
        }
    }

    func testMacRootLayoutKeepsEverythingBelowOneDirectory() {
        let root = URL(fileURLWithPath: "/scratch/aonsoku", isDirectory: true)
        let layout = StorageLayout.macOS(root: root)
        let directories = [
            layout.databaseDirectory, layout.imageCacheDirectory,
            layout.audioCacheDirectory, layout.tailscaleDirectory,
        ] + layout.audioLookupDirectories + layout.audioManagedDirectories

        for directory in directories {
            XCTAssertTrue(
                (directory.path + "/").hasPrefix(root.path + "/"),
                "\(directory.path) escapes the root"
            )
        }
        XCTAssertEqual(layout.databaseFileURL.path, "/scratch/aonsoku/Database/library.sqlite")
    }

    // MARK: Default layout on macOS

    #if os(macOS)
    func testTestProcessesUseAThrowawayLayout() throws {
        // Everything in this process, singletons included, resolves below a
        // per-process scratch directory and never to the user's folders.
        let layout = StorageLayout.current
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [
            layout.databaseDirectory, layout.imageCacheDirectory,
            layout.audioCacheDirectory, layout.tailscaleDirectory,
        ] + layout.audioLookupDirectories + layout.audioManagedDirectories
        // A debug run may also name its own scratch directory.
        var marker = "aonsoku-kit-data-"
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment[PlatformStorage.dataRootVariable],
           !root.isEmpty {
            marker = root
        }
        #endif

        for directory in directories {
            XCTAssertTrue(
                directory.path.contains(marker),
                "\(directory.path) is not in the scratch directory"
            )
            XCTAssertFalse(directory.path.hasPrefix("\(home)/Library/Application Support"))
            XCTAssertFalse(directory.path.hasPrefix("\(home)/Documents"))
        }
    }

    #if DEBUG
    func testDataRootVariableRedirectsEverythingBelowOneDirectory() {
        let layout = PlatformStorage.makeDefault(
            environment: [PlatformStorage.dataRootVariable: "/scratch/data-root"],
            isTestProcess: false
        )
        XCTAssertEqual(layout, StorageLayout.macOS(root: URL(
            fileURLWithPath: "/scratch/data-root", isDirectory: true
        )))
    }

    func testEmptyDataRootVariableIsIgnored() {
        let layout = PlatformStorage.makeDefault(
            environment: [PlatformStorage.dataRootVariable: ""],
            isTestProcess: false
        )
        XCTAssertNotEqual(layout.databaseDirectory.path, "/Database")
        XCTAssertTrue(layout.databaseDirectory.path.hasSuffix(
            "/github.realtvop.aonsoku/Database"
        ))
    }
    #endif

    func testNormalLaunchUsesTheUsersApplicationSupportAndCaches() throws {
        let layout = PlatformStorage.makeDefault(environment: [:], isTestProcess: false)
        let support = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first)
        let caches = try XCTUnwrap(FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first)

        XCTAssertEqual(layout, StorageLayout.macOS(applicationSupport: support, caches: caches))
        XCTAssertTrue(layout.databaseFileURL.path.hasSuffix(
            "/Application Support/github.realtvop.aonsoku/Database/library.sqlite"
        ))
    }

    func testMacHasNoCapacitorDataToImportAndNoDesktopImportOnIOS() {
        XCTAssertFalse(PlatformStorage.supportsLegacyWebImport)
        XCTAssertTrue(PlatformStorage.supportsDesktopDownloadsImport)
    }
    #endif

    // MARK: The legacy WebView importer

    func testLegacyImporterIsNeverNeededWhereCapacitorNeverShipped() async throws {
        let database = try TemporaryDatabase()
        let library = LibraryService(
            dbManager: database.manager,
            credentialsProvider: { nil }
        )
        let preferences = PreferencesService(db: database.manager.dbPool)
        let readerCalls = LockedTestBox(0)
        let importer = LegacyWebDataImporter(
            library: library,
            preferences: preferences,
            reader: {
                readerCalls.update { $0 += 1 }
                return "{\"cacheMeta\":[],\"lyrics\":[],\"customLyrics\":[]}"
            },
            isSupported: false
        )

        XCTAssertFalse(importer.isNeeded)
        let report = await importer.run()
        XCTAssertEqual(report, LegacyImportReport())
        XCTAssertEqual(
            readerCalls.read { $0 },
            0,
            "an unsupported platform must not read WebView data"
        )
        XCTAssertNil(preferences.getString(LegacyWebDataImporter.doneKey))

        #if os(macOS)
        let publicImporter = LegacyWebDataImporter(library: library, preferences: preferences)
        XCTAssertFalse(publicImporter.isNeeded)
        #endif
    }

    // MARK: Components follow the layout

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aonsoku-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testDatabaseManagerOpensTheLibraryOfALayout() throws {
        let root = try scratchDirectory()
        let layout = StorageLayout.macOS(root: root)

        let manager = try DatabaseManager(layout: layout)
        defer { try? manager.dbPool.close() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.databaseFileURL.path))
        XCTAssertEqual(
            layout.databaseFileURL.deletingLastPathComponent().path,
            layout.databaseDirectory.path
        )
    }

    func testAudioAndImageCachesAreCreatedWhereTheLayoutSays() throws {
        let root = try scratchDirectory()
        let layout = StorageLayout.macOS(root: root)

        let audio = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: true, layout: layout)
        let image = try ImageCacheUtils.cacheDirectoryURL(createIfNeeded: true, layout: layout)

        XCTAssertEqual(audio, layout.audioCacheDirectory)
        XCTAssertEqual(image, layout.imageCacheDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }

    func testImageCacheManagerWritesBelowTheLayoutsImageDirectory() throws {
        let root = try scratchDirectory()
        let layout = StorageLayout.macOS(
            applicationSupport: root.appendingPathComponent("Application Support"),
            caches: root.appendingPathComponent("Caches")
        )
        let database = try TemporaryDatabase()
        let manager = ImageCacheManager(
            db: database.manager.dbPool,
            session: URLSession(configuration: .ephemeral),
            credentialsProvider: { nil },
            storage: layout
        )

        let url = try manager.storeCoverImage(
            coverArtId: "cover-1",
            data: Data([1, 2, 3, 4]),
            contentType: "image/jpeg",
            coverSize: "300"
        )

        XCTAssertEqual(url.deletingLastPathComponent().path, layout.imageCacheDirectory.path)
        XCTAssertTrue(url.path.contains("/Caches/github.realtvop.aonsoku/ImageCache/"))
        XCTAssertEqual(manager.resolveCoverImage(coverArtId: "cover-1"), url)
        XCTAssertEqual(try manager.clearCoverImages(), 1)
        XCTAssertNil(manager.resolveCoverImage(coverArtId: "cover-1"))
    }

    func testSourceResolverSearchesTheLayoutsLookupListOnly() throws {
        let parent = try scratchDirectory()
        let electron = try ElectronUserDataFixture(parent: parent)
        try electron.addSong("electron-song")
        let layout = StorageLayout.macOS(
            applicationSupport: electron.applicationSupport,
            caches: parent.appendingPathComponent("Caches")
        )
        let resolver = NativeSourceResolver(storage: layout, credentialsProvider: { nil })

        XCTAssertEqual(resolver.cacheDirectories, [layout.audioCacheDirectory])
        XCTAssertNil(
            resolver.cachedFile(songId: "electron-song"),
            "a download of the Electron app must not be played as the app's own"
        )

        // The app's own copy of another song resolves.
        try FileManager.default.createDirectory(
            at: layout.audioCacheDirectory, withIntermediateDirectories: true
        )
        let own = layout.audioCacheDirectory
            .appendingPathComponent("\(AudioCacheUtils.cacheId(for: "own-song")).mp3")
        try Data([1, 2, 3]).write(to: own)
        XCTAssertEqual(resolver.cachedFile(songId: "own-song"), own)
    }

    // MARK: File management never reaches Electron's folder or Documents

    /// A folder shaped like `~/Documents/AudioCache` of an iOS install, to
    /// show that a Mac layout does not manage it either.
    private func makeDocumentsLookalike(in parent: URL) throws -> URL {
        let documents = parent.appendingPathComponent("Documents", isDirectory: true)
        let audio = documents.appendingPathComponent("AudioCache", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let cacheId = AudioCacheUtils.cacheId(for: "documents-song")
        try Data([9, 9, 9]).write(to: audio.appendingPathComponent("\(cacheId).mp3"))
        try Data("{\"songId\":\"documents-song\",\"fileName\":\"\(cacheId).mp3\",\"contentType\":\"audio/mpeg\",\"lastModifiedAt\":1}".utf8)
            .write(to: audio.appendingPathComponent("\(cacheId).json"))
        try Data("note".utf8).write(to: documents.appendingPathComponent("Notes.txt"))
        return documents
    }

    func testStoreResolveDeleteAndClearStayInTheAppsOwnDirectory() throws {
        let parent = try scratchDirectory()
        let electron = try ElectronUserDataFixture(parent: parent)
        let electronSong = try electron.addSong("electron-song")
        try electron.addSong("electron-flac", contentType: "audio/flac")
        try electron.addInterruptedDownload("electron-partial")
        let documents = try makeDocumentsLookalike(in: parent)
        let layout = StorageLayout.macOS(
            applicationSupport: electron.applicationSupport,
            caches: parent.appendingPathComponent("Caches")
        )
        let electronBefore = try electron.snapshot()
        let documentsBefore = try ElectronUserDataFixture.snapshot(of: documents)

        let database = try TemporaryDatabase()
        let service = AudioService(
            databaseManager: database.manager,
            storage: layout,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        defer { service.shutdown() }

        // Writing: the app's own directory, next to (not in) Electron's.
        let stored = try service.storeAudioFile(
            songId: "own-song", data: Data([1, 2, 3, 4]), contentType: "audio/mpeg"
        )
        let storedURL = try XCTUnwrap(URL(string: stored.uri))
        XCTAssertEqual(
            storedURL.deletingLastPathComponent().standardizedFileURL.path,
            layout.audioCacheDirectory.standardizedFileURL.path
        )
        XCTAssertTrue(layout.audioCacheDirectory.path.hasSuffix(
            "/Application Support/github.realtvop.aonsoku/AudioCache"
        ))

        // Resolving: the app's own files only.
        XCTAssertNotNil(try service.resolveAudioFile(songId: "own-song"))
        XCTAssertNil(try service.resolveAudioFile(songId: "electron-song"))
        XCTAssertNil(try service.resolveAudioFile(songId: "documents-song"))

        // Deleting a song only Electron has deletes nothing.
        XCTAssertFalse(try service.deleteAudioFile(songId: "electron-song"))
        XCTAssertFalse(try service.deleteAudioFile(songId: "documents-song"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: electronSong.audioURL.path))
        XCTAssertEqual(try electron.snapshot(), electronBefore)

        // Clearing counts and removes the app's own audio only.
        XCTAssertEqual(try service.clearAudioFiles(), 1)
        XCTAssertNil(try service.resolveAudioFile(songId: "own-song"))
        XCTAssertEqual(try ElectronUserDataFixture.snapshot(of: documents), documentsBefore)
        XCTAssertEqual(
            try electron.snapshot(),
            electronBefore,
            "clearing the app's downloads changed the Electron folder"
        )
    }

    func testClearingWithoutAnyDownloadsLeavesElectronsFolderAlone() throws {
        let parent = try scratchDirectory()
        let electron = try ElectronUserDataFixture(parent: parent)
        try electron.addSong("electron-song")
        let layout = StorageLayout.macOS(
            applicationSupport: electron.applicationSupport,
            caches: parent.appendingPathComponent("Caches")
        )
        let before = try electron.snapshot()
        let database = try TemporaryDatabase()
        let service = AudioService(
            databaseManager: database.manager,
            storage: layout,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        defer { service.shutdown() }

        XCTAssertEqual(try service.clearAudioFiles(), 0)
        XCTAssertFalse(try service.deleteAudioFile(songId: "electron-song"))
        XCTAssertEqual(try electron.snapshot(), before)
    }

    func testIOSLayoutStillManagesBothDirectoriesItAlwaysDid() throws {
        // The iOS layout over a scratch container: clearing removes the
        // downloads in Documents and the legacy Application Support
        // directory alike, as it did before layouts existed.
        let parent = try scratchDirectory()
        let layout = StorageLayout.iOS(
            applicationSupport: parent.appendingPathComponent("Library/Application Support"),
            documents: parent.appendingPathComponent("Documents")
        )
        let legacy = layout.audioManagedDirectories[1]
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacyId = AudioCacheUtils.cacheId(for: "legacy-song")
        try Data([1]).write(to: legacy.appendingPathComponent("\(legacyId).mp3"))
        let database = try TemporaryDatabase()
        let service = AudioService(
            databaseManager: database.manager,
            storage: layout,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        defer { service.shutdown() }
        _ = try service.storeAudioFile(
            songId: "current-song", data: Data([2]), contentType: "audio/mpeg"
        )

        XCTAssertEqual(try service.clearAudioFiles(), 2)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: legacy.path),
            []
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: layout.audioCacheDirectory.path),
            []
        )
    }
}
