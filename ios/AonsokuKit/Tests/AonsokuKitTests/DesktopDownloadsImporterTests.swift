import XCTest

@testable import AonsokuKit

// Importing the Electron desktop app's downloads.
//
// Every test builds its own "Electron folder" with `ElectronUserDataFixture`
// (mimicking `electron/main/native/audio/cache.ts`) and the app's own layout
// next to it, all in a temporary directory. Nothing here reads or writes the
// real `~/Library/Application Support/Aonsoku` or `~/Documents`.

// MARK: - Fixtures

/// Electron's folder, this app's own layout and its index, in one scratch
/// directory that is made writable again and removed at teardown. Shared with
/// `DesktopImportStoreTests`.
final class ImportWorld {
    /// Later than every date the fixtures use.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let nowMilliseconds = 1_800_000_000_000

    let parent: URL
    let electron: ElectronUserDataFixture
    /// The app's own layout, next to (not inside) Electron's folder.
    let layout: StorageLayout
    let database: TemporaryDatabase
    let index: CacheMetaRepository

    init(_ test: XCTestCase) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aonsoku-import-tests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        self.parent = parent
        // Teardown blocks run last-in first-out, so a fixture made read-only
        // later restores itself before this removes everything.
        test.addTeardownBlock {
            try? ElectronUserDataFixture.setWritable(true, at: parent)
            try? FileManager.default.removeItem(at: parent)
        }
        electron = try ElectronUserDataFixture(parent: parent)
        layout = StorageLayout.macOS(root: parent.appendingPathComponent("app", isDirectory: true))
        database = try TemporaryDatabase()
        index = CacheMetaRepository(db: database.manager.dbPool)
    }

    /// Electron's `userData` folder, found without a picker.
    var location: DesktopDataLocation {
        DesktopDataLocator.location(forDirectory: electron.root, isPicked: false)
    }

    func importer(
        source: DesktopDataLocation? = nil,
        transfer: DesktopFileTransfer = .system,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max / 4 }
    ) -> DesktopDownloadsImporter {
        DesktopDownloadsImporter(
            source: source ?? location,
            storage: layout,
            index: index,
            now: { ImportWorld.now },
            availableCapacity: availableCapacity,
            transfer: transfer
        )
    }

    // MARK: The app's side

    /// File names in the app's audio cache, sorted.
    func appCacheListing() -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(
            atPath: layout.audioCacheDirectory.path
        )
        return (names ?? []).sorted()
    }

    func appFile(for song: ElectronUserDataFixture.Song) -> URL {
        layout.audioCacheDirectory.appendingPathComponent(song.audioURL.lastPathComponent)
    }

    func appMetadata(for song: ElectronUserDataFixture.Song) -> URL {
        layout.audioCacheDirectory.appendingPathComponent(song.metadataURL.lastPathComponent)
    }

    func row(_ songId: String) throws -> CacheMetaRecord? {
        try index.getByKey("audio:\(songId)")
    }

    /// Every index row as one comparable line each (`CacheMetaRecord` is not
    /// `Equatable`).
    func rowFingerprints() throws -> [String] {
        try index.getAll().map {
            [
                $0.key, $0.type, $0.source, String($0.sizeBytes), String($0.cachedAt),
                String($0.lastAccessedAt), $0.removedFromServer.map { String($0) } ?? "nil",
                $0.triggersJson ?? "nil",
            ].joined(separator: "|")
        }.sorted()
    }

    /// A song this app already has, written the way
    /// `AudioService.storeAudioFile` writes it.
    @discardableResult
    func installAppCopy(
        _ songId: String,
        bytes: Data,
        contentType: String = "audio/mpeg"
    ) throws -> URL {
        let directory = layout.audioCacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheId = AudioCacheUtils.cacheId(for: songId)
        let fileName = "\(cacheId).\(AudioCacheUtils.fileExtension(for: contentType))"
        let url = directory.appendingPathComponent(fileName)
        try bytes.write(to: url)
        let metadata = NativeCachedAudioFileMetadata(
            songId: songId, fileName: fileName, contentType: contentType, lastModifiedAt: 5
        )
        try JSONEncoder().encode(metadata).write(
            to: directory.appendingPathComponent("\(cacheId).json")
        )
        return url
    }

    func installRow(
        _ songId: String,
        source: CacheSource,
        size: Int,
        triggers: String? = nil
    ) throws {
        try index.upsert(CacheMetaRecord(
            key: "audio:\(songId)",
            id: songId,
            type: "audio",
            source: source.rawValue,
            triggersJson: triggers,
            coverSize: nil,
            sizeBytes: size,
            cachedAt: 5,
            lastAccessedAt: 6,
            removedFromServer: false
        ))
    }

    // MARK: Electron's side

    /// `<cacheId(name)>.json` holding `json`, with `<cacheId(name)>.mp3`
    /// beside it unless told otherwise.
    func plant(name: String, json: String, audio: Bool = true) throws {
        let cacheId = AudioCacheUtils.cacheId(for: name)
        if audio {
            try Data("audio".utf8).write(
                to: electron.audioCache.appendingPathComponent("\(cacheId).mp3")
            )
        }
        try Data(json.utf8).write(to: electron.audioCache.appendingPathComponent("\(cacheId).json"))
    }

    static func quote(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Metadata JSON; `time` is spliced in as it is, so a test can make it a
    /// string or leave it out.
    static func json(
        _ songId: String,
        _ fileName: String,
        contentType: String = "audio/mpeg",
        time: String = "1700000000000"
    ) -> String {
        "{\"songId\":\(quote(songId)),\"fileName\":\(quote(fileName)),"
            + "\"contentType\":\(quote(contentType)),\"lastModifiedAt\":\(time)}"
    }

    /// The `<cacheId>.mp3` name `plant` gives a song's audio.
    static func mp3(_ name: String) -> String {
        "\(AudioCacheUtils.cacheId(for: name)).mp3"
    }
}

extension DesktopFileTransfer {
    /// The copy that works across volumes and on file systems without clones.
    static let streaming = DesktopFileTransfer { source, destination, isCancelled in
        try DesktopFileCopier.stream(from: source, to: destination, isCancelled: isCancelled)
    }
}

// MARK: - Importer

final class DesktopDownloadsImporterTests: XCTestCase {
    // MARK: Scanning

    func testScanFindsCompleteDownloadsAndIgnoresInterruptedWrites() throws {
        let world = try ImportWorld(self)
        let alpha = try world.electron.addSong(
            "alpha", size: 4_096, lastModifiedAt: 1_700_000_000_001
        )
        let beta = try world.electron.addSong(
            "beta", contentType: "audio/flac", size: 9_000, lastModifiedAt: 1_700_000_000_002
        )
        let accented = try world.electron.addSong(
            "track-é-曲-1", contentType: "audio/mp4", size: 100
        )
        try world.electron.addInterruptedDownload("partial")
        try world.electron.addInterruptedMetadata("half-written")
        // Audio whose metadata was never written (a crash between the two).
        let orphanId = AudioCacheUtils.cacheId(for: "orphan")
        try Data(repeating: 1, count: 10).write(
            to: world.electron.audioCache.appendingPathComponent("\(orphanId).mp3")
        )

        let scan = try world.importer().scanAudioCache()

        let byId = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.songId, $0) })
        XCTAssertEqual(Set(byId.keys), ["alpha", "beta", "track-é-曲-1"])
        XCTAssertEqual(scan.skipped, 0, "interrupted writes are neither downloads nor failures")
        XCTAssertEqual(scan.songCount, 3)
        XCTAssertEqual(scan.totalBytes, 4_096 + 9_000 + 100)

        let entry = try XCTUnwrap(byId["beta"])
        XCTAssertEqual(entry.cacheId, beta.cacheId)
        XCTAssertEqual(entry.fileName, beta.audioURL.lastPathComponent)
        XCTAssertEqual(entry.contentType, "audio/flac")
        XCTAssertEqual(entry.lastModifiedAt, 1_700_000_000_002)
        XCTAssertEqual(entry.sizeBytes, 9_000)
        XCTAssertEqual(byId["alpha"]?.fileName, alpha.audioURL.lastPathComponent)
        XCTAssertEqual(byId["track-é-曲-1"]?.fileName, accented.audioURL.lastPathComponent)
    }

    func testScanRejectsMetadataThatDoesNotDescribeItsOwnFile() throws {
        let world = try ImportWorld(self)
        try world.electron.addSong("good")
        let other = try world.electron.addSong("other")
        let otherAudio = other.audioURL.lastPathComponent
        var planted = 0
        func plant(_ name: String, _ json: String, audio: Bool = true) throws {
            try world.plant(name: name, json: json, audio: audio)
            planted += 1
        }

        // Mismatched ids.
        // Filed under one song's name, describing another song.
        try plant("liar-1", ImportWorld.json("other", otherAudio))
        // The right song, but another song's audio file.
        try plant("liar-2", ImportWorld.json("liar-2", otherAudio))
        // The id inside is not the one the file name stands for.
        try plant("liar-3", ImportWorld.json("liar-3-renamed", ImportWorld.mp3("liar-3")))

        // File names that are not plain names.
        for (offset, name) in
            ["../escape.mp3", "/etc/hosts", "sub/dir.mp3", "..", ".", "back\\slash.mp3"]
                .enumerated()
        {
            let song = "path-\(offset)"
            try plant(song, ImportWorld.json(song, name))
        }

        // Extensions that cannot be audio.
        for (offset, ext) in ["tmp", "abcdefghi", "mp3.bak", "m p3"].enumerated() {
            let song = "ext-\(offset)"
            let fileName = "\(AudioCacheUtils.cacheId(for: song)).\(ext)"
            try Data("audio".utf8).write(
                to: world.electron.audioCache.appendingPathComponent(fileName)
            )
            try plant(song, ImportWorld.json(song, fileName), audio: false)
        }
        // Metadata naming itself as the audio file.
        let selfName = "\(AudioCacheUtils.cacheId(for: "self")).json"
        try plant("self", ImportWorld.json("self", selfName), audio: false)

        // Values of the wrong kind.
        try plant("empty-type", ImportWorld.json("empty-type", ImportWorld.mp3("empty-type"), contentType: "  "))
        try plant("negative", ImportWorld.json("negative", ImportWorld.mp3("negative"), time: "-5"))
        try plant("string-time", ImportWorld.json("string-time", ImportWorld.mp3("string-time"), time: "\"1700\""))
        try plant(
            "missing-time",
            "{\"songId\":\"missing-time\",\"fileName\":\"\(ImportWorld.mp3("missing-time"))\","
                + "\"contentType\":\"audio/mpeg\"}"
        )
        try plant("not-json", "this is not json")
        try plant("array", "[]")
        try plant("empty-file", "")
        try plant("huge", ImportWorld.json(
            "huge", ImportWorld.mp3("huge"), contentType: String(repeating: "x", count: 70_000)
        ))

        // Metadata whose audio is missing or empty.
        try plant("no-audio", ImportWorld.json("no-audio", ImportWorld.mp3("no-audio")), audio: false)
        try plant("empty-audio", ImportWorld.json("empty-audio", ImportWorld.mp3("empty-audio")), audio: false)
        try Data().write(
            to: world.electron.audioCache.appendingPathComponent(ImportWorld.mp3("empty-audio"))
        )

        let scan = try world.importer().scanAudioCache()

        XCTAssertEqual(Set(scan.entries.map(\.songId)), ["good", "other"])
        XCTAssertEqual(scan.skipped, planted)
        XCTAssertEqual(world.appCacheListing(), [], "scanning wrote to the app's cache")
    }

    func testScanSkipsSymbolicLinks() throws {
        let world = try ImportWorld(self)
        let cache = world.electron.audioCache
        let fileManager = FileManager.default

        // An audio file that is a link to a real file elsewhere in the folder.
        let target = world.electron.root.appendingPathComponent("store/real.mp3")
        try Data(repeating: 7, count: 64).write(to: target)
        let linkedAudio = ImportWorld.mp3("linked-audio")
        try fileManager.createSymbolicLink(
            at: cache.appendingPathComponent(linkedAudio), withDestinationURL: target
        )
        try world.plant(
            name: "linked-audio", json: ImportWorld.json("linked-audio", linkedAudio), audio: false
        )

        // Metadata that is a link to a perfectly valid description.
        let linkedMetaAudio = ImportWorld.mp3("linked-meta")
        try Data(repeating: 8, count: 64).write(to: cache.appendingPathComponent(linkedMetaAudio))
        let metaTarget = world.electron.root.appendingPathComponent("store/meta-target.json")
        try Data(ImportWorld.json("linked-meta", linkedMetaAudio).utf8).write(to: metaTarget)
        try fileManager.createSymbolicLink(
            at: cache.appendingPathComponent("\(AudioCacheUtils.cacheId(for: "linked-meta")).json"),
            withDestinationURL: metaTarget
        )

        let scan = try world.importer().scanAudioCache()

        XCTAssertEqual(scan.entries, [])
        XCTAssertEqual(scan.skipped, 2)
    }

    func testMissingDownloadsFolderInAReadableDataFolderIsEmptyNotAnError() throws {
        let world = try ImportWorld(self)
        try FileManager.default.removeItem(at: world.electron.audioCache)

        let scan = try world.importer().scanAudioCache()

        XCTAssertEqual(scan, DesktopDownloadsScan(entries: [], skipped: 0))
        let result = try world.importer().importAudioCache()
        XCTAssertEqual(result, DesktopImportResult())
    }

    func testMissingOrUnreadableFoldersAreReportedAsUnreadable() throws {
        let world = try ImportWorld(self)
        let missing = DesktopDataLocator.location(
            forDirectory: world.parent.appendingPathComponent("nothing-here", isDirectory: true),
            isPicked: true
        )
        XCTAssertThrowsError(try world.importer(source: missing).scanAudioCache()) {
            XCTAssertEqual($0 as? DesktopImportError, .sourceUnreadable)
        }
        XCTAssertThrowsError(try world.importer(source: missing).importAudioCache()) {
            XCTAssertEqual($0 as? DesktopImportError, .sourceUnreadable)
        }

        // A file where the downloads folder should be.
        let file = world.parent.appendingPathComponent("a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file.appendingPathComponent("AudioCache"))
        XCTAssertThrowsError(try world.importer(
            source: DesktopDataLocator.location(forDirectory: file, isPicked: true)
        ).scanAudioCache()) {
            XCTAssertEqual($0 as? DesktopImportError, .sourceUnreadable)
        }

        // A folder this process may not read (a sandbox says the same).
        let cache = world.electron.audioCache
        try world.electron.addSong("hidden")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cache.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.path)
        }
        XCTAssertThrowsError(try world.importer().scanAudioCache()) {
            XCTAssertEqual($0 as? DesktopImportError, .sourceUnreadable)
        }
        XCTAssertEqual(world.appCacheListing(), [])
    }

    // MARK: Importing

    func testImportCopiesBytesWritesMetadataAndRegistersExplicitDownloads() throws {
        let world = try ImportWorld(self)
        let songs = try [
            world.electron.addSong("alpha", size: 4_096, lastModifiedAt: 1_700_000_000_001),
            world.electron.addSong(
                "beta", contentType: "audio/flac", size: 100_000, lastModifiedAt: 1_700_000_000_002
            ),
            world.electron.addSong(
                "track-é-曲-1", contentType: "audio/mp4", size: 33, lastModifiedAt: 1_700_000_000_003
            ),
        ]

        let result = try world.importer().importAudioCache()

        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(result.alreadyPresent, 0)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.bytesCopied, 4_096 + 100_000 + 33)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertFalse(result.ranOutOfSpace)

        let resolver = NativeSourceResolver(storage: world.layout, credentialsProvider: { nil })
        for song in songs {
            XCTAssertEqual(try Data(contentsOf: world.appFile(for: song)), song.data, song.id)
            let stored = try JSONDecoder().decode(
                NativeCachedAudioFileMetadata.self,
                from: Data(contentsOf: world.appMetadata(for: song))
            )
            XCTAssertEqual(stored.songId, song.id)
            XCTAssertEqual(stored.fileName, song.audioURL.lastPathComponent)
            XCTAssertEqual(stored.contentType, song.contentType)
            XCTAssertEqual(stored.lastModifiedAt, Double(song.lastModifiedAt))

            let row = try XCTUnwrap(try world.row(song.id), song.id)
            XCTAssertEqual(row.key, "audio:\(song.id)")
            XCTAssertEqual(row.id, song.id)
            XCTAssertEqual(row.type, "audio")
            XCTAssertEqual(row.source, "explicit", "downloads are never evicted")
            XCTAssertEqual(row.sizeBytes, song.data.count)
            XCTAssertEqual(row.cachedAt, song.lastModifiedAt, "kept the date it was downloaded on")
            XCTAssertEqual(row.lastAccessedAt, ImportWorld.nowMilliseconds)
            XCTAssertEqual(row.removedFromServer, false)
            XCTAssertNil(row.triggersJson)
            XCTAssertNil(row.coverSize)

            XCTAssertEqual(
                resolver.cachedFile(songId: song.id)?.path,
                world.appFile(for: song).path,
                "playback finds the imported file"
            )
        }
        // Audio and metadata per song, and nothing else.
        XCTAssertEqual(world.appCacheListing().count, 6)
        XCTAssertEqual(world.appCacheListing().filter { $0.hasSuffix(".tmp") }, [])
    }

    func testImportKeepsADownloadDateInTheFutureOutOfTheIndex() throws {
        let world = try ImportWorld(self)
        // A desktop clock that was wrong when the file was written.
        let song = try world.electron.addSong(
            "from-the-future", lastModifiedAt: ImportWorld.nowMilliseconds + 86_400_000
        )
        try world.electron.addSong("from-1970", lastModifiedAt: 0)

        _ = try world.importer().importAudioCache()

        XCTAssertEqual(try world.row(song.id)?.cachedAt, ImportWorld.nowMilliseconds)
        XCTAssertEqual(try world.row("from-1970")?.cachedAt, ImportWorld.nowMilliseconds)
    }

    func testReadOnlyDesktopFolderStaysByteIdenticalWhetherCopiedByCloneOrStream() throws {
        for (label, transfer) in
            [("system", DesktopFileTransfer.system), ("streaming", DesktopFileTransfer.streaming)]
        {
            let world = try ImportWorld(self)
            let songs = try [
                world.electron.addSong("one", size: 5_000),
                world.electron.addSong("two", contentType: "audio/flac", size: 3 * 1_024 * 1_024 + 17),
            ]
            try world.electron.addInterruptedDownload("partial")
            try world.electron.addInterruptedMetadata("half")
            try world.electron.makeReadOnly(for: self)
            let before = try world.electron.snapshot()

            let importer = world.importer(transfer: transfer)
            _ = try importer.scanAudioCache()
            _ = try importer.scanAndPlan()
            let first = try importer.importAudioCache()
            let second = try importer.importAudioCache()

            XCTAssertEqual(first.imported, 2, label)
            XCTAssertEqual(second.alreadyPresent, 2, label)
            XCTAssertEqual(
                try world.electron.snapshot(), before,
                "\(label): the desktop folder changed (names, bytes, modes or times)"
            )
            // The copies are the app's own, writable files, whatever the
            // source's mode was: the app can delete them again.
            for song in songs {
                XCTAssertEqual(try Data(contentsOf: world.appFile(for: song)), song.data, label)
                for url in [world.appFile(for: song), world.appMetadata(for: song)] {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    XCTAssertNotEqual(
                        mode & 0o200, 0,
                        "\(label): \(url.lastPathComponent) is read-only (\(String(mode, radix: 8)))"
                    )
                }
            }
            for name in world.appCacheListing() {
                try FileManager.default.removeItem(
                    at: world.layout.audioCacheDirectory.appendingPathComponent(name)
                )
            }
            XCTAssertEqual(try world.electron.snapshot(), before, label)
        }
    }

    func testImportingAgainChangesNothing() throws {
        let world = try ImportWorld(self)
        try world.electron.addSong("one")
        try world.electron.addSong("two", contentType: "audio/flac")
        let first = try world.importer().importAudioCache()
        XCTAssertEqual(first.imported, 2)
        let cacheBefore = try ElectronUserDataFixture.snapshot(of: world.layout.audioCacheDirectory)
        let rowsBefore = try world.rowFingerprints()
        XCTAssertEqual(rowsBefore.count, 2)

        let second = try world.importer().importAudioCache()
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.alreadyPresent, 2)
        XCTAssertEqual(second.bytesCopied, 0)
        XCTAssertEqual(second.failures, [])
        XCTAssertEqual(
            try ElectronUserDataFixture.snapshot(of: world.layout.audioCacheDirectory), cacheBefore,
            "an up-to-date import rewrote files"
        )
        XCTAssertEqual(try world.rowFingerprints(), rowsBefore)

        // Much later, with nothing to do, the index still does not move.
        var later = world.importer()
        later.now = { Date(timeIntervalSince1970: 1_900_000_000) }
        _ = try later.importAudioCache()
        XCTAssertEqual(try world.rowFingerprints(), rowsBefore)

        let plan = try world.importer().scanAndPlan().plan
        XCTAssertEqual(plan.pendingCount, 0)
        XCTAssertEqual(plan.upToDate, 2)
    }

    func testImportCarriesOnFromWhereACancelledRunStopped() throws {
        let world = try ImportWorld(self)
        for id in ["song-1", "song-2", "song-3"] { try world.electron.addSong(id) }
        let cancelled = LockedTestBox(false)
        let transfer = DesktopFileTransfer { source, destination, isCancelled in
            try DesktopFileCopier.copy(from: source, to: destination, isCancelled: isCancelled)
            cancelled.update { $0 = true } // the user cancels while song 1 is done
        }

        let first = try world.importer(transfer: transfer).importAudioCache(
            cancel: { cancelled.read { $0 } }
        )

        XCTAssertTrue(first.wasCancelled)
        XCTAssertEqual(first.imported, 1)
        XCTAssertNotNil(try world.row("song-1"))
        XCTAssertNil(try world.row("song-2"))
        XCTAssertEqual(world.appCacheListing().count, 2, "only the finished song is in the cache")

        let second = try world.importer().importAudioCache()
        XCTAssertFalse(second.wasCancelled)
        XCTAssertEqual(second.imported, 2)
        XCTAssertEqual(second.alreadyPresent, 1)
        XCTAssertEqual(world.appCacheListing().count, 6)
        for id in ["song-1", "song-2", "song-3"] {
            XCTAssertEqual(try world.row(id)?.source, "explicit", id)
        }
    }

    func testCancellingBetweenChunksLeavesNoPartialFile() throws {
        let world = try ImportWorld(self)
        try world.electron.addSong("big", size: 3 * 1_024 * 1_024)
        let polls = LockedTestBox(0)

        let result = try world.importer(transfer: .streaming).importAudioCache(cancel: {
            // Once before the song, then once per 1 MiB chunk: stop in the middle.
            polls.update { $0 += 1 }
            return polls.read { $0 } >= 3
        })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.failures, [], "cancelling is not a failure")
        XCTAssertEqual(world.appCacheListing(), [], "a partial copy was left behind")
        XCTAssertNil(try world.row("big"))
    }

    func testOneFailingSongDoesNotStopTheOthers() throws {
        let world = try ImportWorld(self)
        for id in ["song-1", "bad", "song-3"] { try world.electron.addSong(id) }
        let badCacheId = AudioCacheUtils.cacheId(for: "bad")
        let transfer = DesktopFileTransfer { source, destination, isCancelled in
            if destination.lastPathComponent.hasPrefix(badCacheId) { throw POSIXError(.EIO) }
            try DesktopFileCopier.copy(from: source, to: destination, isCancelled: isCancelled)
        }

        let result = try world.importer(transfer: transfer).importAudioCache()

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.failures, [DesktopImportFailure(songId: "bad", reason: .copyFailed)])
        XCTAssertEqual(result.available, 2)
        XCTAssertFalse(result.ranOutOfSpace)
        XCTAssertNil(try world.row("bad"))
        XCTAssertEqual(try world.row("song-1")?.source, "explicit")
        XCTAssertEqual(try world.row("song-3")?.source, "explicit")
        XCTAssertFalse(world.appCacheListing().contains { $0.hasPrefix(badCacheId) })
        XCTAssertEqual(world.appCacheListing().filter { $0.hasSuffix(".tmp") }, [])

        // The failure is not remembered: the next run copies it.
        let retry = try world.importer().importAudioCache()
        XCTAssertEqual(retry.imported, 1)
        XCTAssertEqual(retry.alreadyPresent, 2)
        XCTAssertNotNil(try world.row("bad"))
    }

    func testRunningOutOfSpaceStopsTheRunAndKeepsWhatWasDone() throws {
        let world = try ImportWorld(self)
        for id in ["song-1", "song-2", "song-3"] { try world.electron.addSong(id) }
        let secondCacheId = AudioCacheUtils.cacheId(for: "song-2")
        let transfer = DesktopFileTransfer { source, destination, isCancelled in
            if destination.lastPathComponent.hasPrefix(secondCacheId) { throw POSIXError(.ENOSPC) }
            try DesktopFileCopier.copy(from: source, to: destination, isCancelled: isCancelled)
        }

        let result = try world.importer(transfer: transfer).importAudioCache()

        XCTAssertTrue(result.ranOutOfSpace)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.failures, [DesktopImportFailure(songId: "song-2", reason: .diskFull)])
        XCTAssertNotNil(try world.row("song-1"))
        XCTAssertNil(try world.row("song-2"))
        XCTAssertNil(try world.row("song-3"), "the run went on after the disk filled up")
        XCTAssertEqual(world.appCacheListing().count, 2)

        let resumed = try world.importer().importAudioCache()
        XCTAssertEqual(resumed.imported, 2)
        XCTAssertFalse(resumed.ranOutOfSpace)
    }

    func testNotEnoughFreeSpaceIsReportedBeforeAnythingIsCopied() throws {
        let world = try ImportWorld(self)
        try world.electron.addSong("one", size: 4_096)
        try world.electron.addSong("two", size: 5_000)

        XCTAssertThrowsError(
            try world.importer(availableCapacity: { _ in 1_000 }).importAudioCache()
        ) { error in
            guard case let .insufficientSpace(required, available)? = error as? DesktopImportError
            else { return XCTFail("\(error)") }
            XCTAssertEqual(available, 1_000)
            XCTAssertEqual(required, 4_096 + 5_000 + 64 * 1_024 * 1_024)
        }
        XCTAssertEqual(world.appCacheListing(), [])
        XCTAssertNil(try world.row("one"))

        // Free space is not asked of an import that copies nothing.
        _ = try world.importer().importAudioCache()
        let nothingToCopy = try world.importer(availableCapacity: { _ in 0 }).importAudioCache()
        XCTAssertEqual(nothingToCopy.alreadyPresent, 2)

        // The real figure is a positive number.
        XCTAssertGreaterThan(DesktopDownloadsImporter.availableCapacity(at: world.parent) ?? 0, 0)
    }

    func testSourceFilesThatChangeDuringTheRunAreReportedNotImported() throws {
        let world = try ImportWorld(self)
        let songs = try ["song-1", "song-2", "song-3"].map { try world.electron.addSong($0) }
        var changed = false

        let result = try world.importer().importAudioCache(progress: { progress in
            guard progress.completed == 0, !changed else { return }
            changed = true
            // The desktop app deletes one download and rewrites another.
            try? FileManager.default.removeItem(at: songs[1].audioURL)
            try? Data(count: 10).write(to: songs[2].audioURL)
        })

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.failures.map(\.songId), ["song-2", "song-3"])
        XCTAssertEqual(Set(result.failures.map(\.reason)), [.sourceChanged])
        XCTAssertNil(try world.row("song-2"))
        XCTAssertNil(try world.row("song-3"))
        XCTAssertEqual(world.appCacheListing().count, 2)
    }

    func testACopyShorterThanItsSourceIsNeverPublished() throws {
        let world = try ImportWorld(self)
        try world.electron.addSong("short", size: 4_096)
        let transfer = DesktopFileTransfer { source, destination, _ in
            let data = try Data(contentsOf: source)
            try data.prefix(data.count / 2).write(to: destination)
        }

        let result = try world.importer(transfer: transfer).importAudioCache()

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.failures, [DesktopImportFailure(songId: "short", reason: .incomplete)])
        XCTAssertEqual(world.appCacheListing(), [], "the truncated copy or its metadata was kept")
        XCTAssertNil(try world.row("short"))
    }

    func testAlinkSwappedInAsTheCopyIsRefused() throws {
        let world = try ImportWorld(self)
        try world.electron.addSong("linked", size: 4_096)
        let outside = world.parent.appendingPathComponent("outside.bin")
        try Data(repeating: 3, count: 4_096).write(to: outside)
        // A transfer that leaves a symbolic link where the copy should be.
        let transfer = DesktopFileTransfer { _, destination, _ in
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        }

        let result = try world.importer(transfer: transfer).importAudioCache()

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.failures, [DesktopImportFailure(songId: "linked", reason: .incomplete)])
        XCTAssertEqual(world.appCacheListing(), [])
        XCTAssertEqual(try Data(contentsOf: outside), Data(repeating: 3, count: 4_096))
    }

    func testStreamingCopierRefusesLinksAndExistingDestinations() throws {
        let world = try ImportWorld(self)
        let source = world.parent.appendingPathComponent("source.bin")
        let payload = Data((0..<(2 * 1_024 * 1_024 + 5)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try payload.write(to: source)

        let copy = world.parent.appendingPathComponent("copy.bin")
        try DesktopFileCopier.stream(from: source, to: copy, isCancelled: { false })
        XCTAssertEqual(try Data(contentsOf: copy), payload)

        // An existing destination is never overwritten.
        XCTAssertThrowsError(
            try DesktopFileCopier.stream(from: source, to: copy, isCancelled: { false })
        )
        XCTAssertEqual(try Data(contentsOf: copy), payload)

        // A link is not followed.
        let link = world.parent.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let linkCopy = world.parent.appendingPathComponent("link-copy.bin")
        XCTAssertThrowsError(
            try DesktopFileCopier.stream(from: link, to: linkCopy, isCancelled: { false })
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkCopy.path))

        // A cancelled copy leaves nothing.
        let cancelledCopy = world.parent.appendingPathComponent("cancelled.bin")
        XCTAssertThrowsError(
            try DesktopFileCopier.stream(from: source, to: cancelledCopy, isCancelled: { true })
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledCopy.path))

        // The clone is byte-identical too (where the volume supports it).
        let cloned = world.parent.appendingPathComponent("cloned.bin")
        if DesktopFileCopier.clone(from: source, to: cloned) {
            XCTAssertEqual(try Data(contentsOf: cloned), payload)
            XCTAssertFalse(DesktopFileCopier.clone(from: source, to: cloned), "overwrote a file")
        }
    }

    func testRefusesAFolderThatIsOrContainsTheAppsOwnCache() throws {
        let world = try ImportWorld(self)
        try world.electron.addSong("electron-song")
        let own = try world.installAppCopy("own-song", bytes: Data(repeating: 9, count: 100))
        let before = try ElectronUserDataFixture.snapshot(of: world.layout.audioCacheDirectory)

        // The user picks the app's own downloads folder.
        let ownCache = DesktopDataLocation(
            directory: world.layout.audioCacheDirectory.deletingLastPathComponent(),
            audioCacheDirectory: world.layout.audioCacheDirectory,
            isPicked: true
        )
        XCTAssertThrowsError(try world.importer(source: ownCache).importAudioCache()) {
            XCTAssertEqual($0 as? DesktopImportError, .sourceIsDestination)
        }
        // A folder that holds both Electron's data and the app's.
        let both = DesktopDataLocator.location(forDirectory: world.parent, isPicked: true)
        XCTAssertThrowsError(try world.importer(source: both).importAudioCache()) {
            XCTAssertEqual($0 as? DesktopImportError, .sourceIsDestination)
        }

        XCTAssertEqual(try Data(contentsOf: own), Data(repeating: 9, count: 100))
        XCTAssertEqual(
            try ElectronUserDataFixture.snapshot(of: world.layout.audioCacheDirectory), before
        )
        XCTAssertNil(try world.row("electron-song"))
    }

    func testSongsTheAppAlreadyHasAreRegisteredAsDownloadsNotCopied() throws {
        let world = try ImportWorld(self)
        for id in ["streamed", "smart", "index-lost", "stale-size", "fresh"] {
            try world.electron.addSong(id, size: 4_096, lastModifiedAt: 1_700_000_000_000)
        }
        // The app's own copies are different, shorter bytes: they must stay.
        let ownBytes = Data(repeating: 9, count: 100)
        var ownFiles: [String: URL] = [:]
        for id in ["streamed", "smart", "index-lost", "stale-size"] {
            ownFiles[id] = try world.installAppCopy(id, bytes: ownBytes)
        }
        try world.installRow("streamed", source: .lru, size: 100)
        try world.installRow("smart", source: .smart, size: 100, triggers: "[\"favorite\"]")
        try world.installRow("stale-size", source: .explicit, size: 1)

        let plan = try world.importer().scanAndPlan().plan
        XCTAssertEqual(plan.copies.map(\.songId), ["fresh"])
        XCTAssertEqual(Set(plan.promotions.map(\.songId)), ["streamed", "smart", "index-lost", "stale-size"])
        XCTAssertEqual(plan.copyBytes, 4_096)

        let result = try world.importer().importAudioCache()

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.alreadyPresent, 4)
        XCTAssertEqual(result.bytesCopied, 4_096)
        for (id, url) in ownFiles {
            XCTAssertEqual(try Data(contentsOf: url), ownBytes, "\(id): the app's copy was replaced")
        }
        for id in ["streamed", "smart", "index-lost", "stale-size"] {
            let row = try XCTUnwrap(try world.row(id), id)
            XCTAssertEqual(row.source, "explicit", id)
            XCTAssertEqual(row.sizeBytes, 100, "\(id): the size of the file that is kept")
        }
        // Streamed and smart rows keep their dates; an index that was lost
        // gets the date the desktop app downloaded the song.
        XCTAssertEqual(try world.row("streamed")?.cachedAt, 5)
        XCTAssertEqual(try world.row("smart")?.triggersJson, "[\"favorite\"]")
        XCTAssertEqual(try world.row("index-lost")?.cachedAt, 1_700_000_000_000)
        XCTAssertEqual(try world.row("fresh")?.sizeBytes, 4_096)
    }

    func testMismatchedMetadataIsNeverImported() throws {
        let world = try ImportWorld(self)
        let good = try world.electron.addSong("good")
        let other = try world.electron.addSong("other")
        // A file that claims a different song than its name stands for, with
        // an audio file that is really another song's.
        try world.plant(
            name: "forged",
            json: ImportWorld.json("victim", other.audioURL.lastPathComponent),
            audio: false
        )

        let result = try world.importer().importAudioCache()

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertNil(try world.row("victim"))
        XCTAssertNil(try world.row("forged"))
        XCTAssertEqual(
            world.appCacheListing(),
            [
                good.audioURL.lastPathComponent, good.metadataURL.lastPathComponent,
                other.audioURL.lastPathComponent, other.metadataURL.lastPathComponent,
            ].sorted()
        )
        XCTAssertEqual(
            try Data(contentsOf: world.appFile(for: other)), other.data,
            "the other song's audio must still be its own"
        )
    }

    func testStaleTemporaryFilesAreRemovedAndInterruptedPublishesAreRepaired() throws {
        let world = try ImportWorld(self)
        let song = try world.electron.addSong("repair", size: 4_096)
        let directory = world.layout.audioCacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // What an interrupted earlier run left: a temporary copy ...
        let stale = directory.appendingPathComponent(
            "\(song.cacheId).import-\(UUID().uuidString).tmp"
        )
        try Data("partial".utf8).write(to: stale)
        // ... and an audio file renamed into place whose metadata never came.
        let unfinished = world.appFile(for: song)
        try Data(repeating: 1, count: 10).write(to: unfinished)
        // Files that are not the importer's stay.
        let unrelated = directory.appendingPathComponent("unrelated.mp3")
        try Data("keep".utf8).write(to: unrelated)

        let result = try world.importer().importAudioCache()

        XCTAssertEqual(result.imported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try Data(contentsOf: unfinished), song.data)
        XCTAssertNotNil(try world.row("repair"))
    }

    func testProgressStartsAtZeroAndEndsAtTheTotal() throws {
        let world = try ImportWorld(self)
        for id in ["song-1", "song-2", "song-3"] { try world.electron.addSong(id, size: 1_000) }
        var seen: [DesktopImportProgress] = []

        _ = try world.importer().importAudioCache(progress: { seen.append($0) })

        XCTAssertEqual(seen.map(\.completed), [0, 1, 2, 3])
        XCTAssertTrue(seen.allSatisfy { $0.total == 3 && $0.totalBytes == 3_000 })
        XCTAssertEqual(seen.first?.bytesCopied, 0)
        XCTAssertEqual(seen.first?.fraction, 0)
        XCTAssertEqual(seen.last?.bytesCopied, 3_000)
        XCTAssertEqual(seen.last?.fraction, 1)
        XCTAssertEqual(seen.map(\.bytesCopied), seen.map(\.bytesCopied).sorted())
    }

    func testOnlyTheAppsOwnFolderIsEverWritten() throws {
        // The desktop folder is read through a locator that points at it, while
        // the app's layout is elsewhere: the scratch parent holds only these two.
        let world = try ImportWorld(self)
        try world.electron.addSong("song-1")
        try world.electron.addSong("song-2", contentType: "audio/flac")
        let parentBefore = try ElectronUserDataFixture.snapshot(of: world.parent)

        _ = try world.importer().importAudioCache()
        let parentAfter = try ElectronUserDataFixture.snapshot(of: world.parent)

        let changed = Set(parentAfter.keys).symmetricDifference(parentBefore.keys)
            .union(parentBefore.keys.filter { parentAfter[$0] != parentBefore[$0] })
        let outsideTheApp = changed.filter {
            !($0 == "app" || $0.hasPrefix("app/"))
        }
        XCTAssertEqual(outsideTheApp.sorted(), [], "files outside the app's folder changed")
        XCTAssertFalse(changed.isEmpty)
    }
}

// MARK: - Locating the desktop app's data

#if os(macOS)
final class DesktopDataLocatorTests: XCTestCase {
    func testTheDefaultLocationIsTheRealApplicationSupportFolder() throws {
        let home = try XCTUnwrap(DesktopDataLocator.realHomeDirectory())
        let location = try XCTUnwrap(DesktopDataLocator.defaultLocation(environment: [:]))

        XCTAssertEqual(
            location.directory.path,
            home.appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Aonsoku", isDirectory: true).path
        )
        XCTAssertEqual(location.audioCacheDirectory.path, location.directory.path + "/AudioCache")
        XCTAssertFalse(location.isPicked)
        XCTAssertEqual(
            DesktopDataLocator.applicationSupportDirectory?.path,
            location.directory.deletingLastPathComponent().path
        )
    }

    func testTheDefaultLocationIsNeverTheAppsOwnStorage() throws {
        let support = try XCTUnwrap(DesktopDataLocator.applicationSupportDirectory)
        let layout = StorageLayout.macOS(
            applicationSupport: support,
            caches: support.deletingLastPathComponent().appendingPathComponent("Caches")
        )
        let location = try XCTUnwrap(DesktopDataLocator.defaultLocation(environment: [:]))

        XCTAssertFalse(DesktopDownloadsImporter.overlap(layout.audioCacheDirectory, location.directory))
        XCTAssertFalse(DesktopDownloadsImporter.overlap(layout.databaseDirectory, location.directory))
        XCTAssertFalse(DesktopDownloadsImporter.overlap(
            StorageLayout.current.audioCacheDirectory, location.directory
        ), "the layout of this process reaches the desktop app's folder")
    }

    func testTheDebugOverrideRedirectsTheDefaultToAScratchFolder() throws {
        #if DEBUG
        let location = try XCTUnwrap(DesktopDataLocator.defaultLocation(
            environment: [DesktopDataLocator.overrideVariable: "/tmp/scratch-desktop"]
        ))
        XCTAssertEqual(location.directory.path, "/tmp/scratch-desktop")
        XCTAssertEqual(location.audioCacheDirectory.path, "/tmp/scratch-desktop/AudioCache")
        XCTAssertFalse(location.isPicked)

        let empty = try XCTUnwrap(DesktopDataLocator.defaultLocation(
            environment: [DesktopDataLocator.overrideVariable: ""]
        ))
        XCTAssertEqual(empty.directory.lastPathComponent, "Aonsoku", "an empty override is ignored")
        #endif
    }

    func testPickingEitherTheDataFolderOrItsDownloadsFolder() throws {
        let data = URL(fileURLWithPath: "/tmp/picked/Aonsoku", isDirectory: true)
        let fromData = try XCTUnwrap(DesktopDataLocator.location(forPicked: data))
        XCTAssertEqual(fromData.directory.path, "/tmp/picked/Aonsoku")
        XCTAssertEqual(fromData.audioCacheDirectory.path, "/tmp/picked/Aonsoku/AudioCache")
        XCTAssertTrue(fromData.isPicked)
        XCTAssertEqual(fromData.accessURL.path, "/tmp/picked/Aonsoku")

        let cache = URL(fileURLWithPath: "/tmp/picked/Aonsoku/AudioCache/", isDirectory: true)
        let fromCache = try XCTUnwrap(DesktopDataLocator.location(forPicked: cache))
        XCTAssertEqual(fromCache.directory.path, "/tmp/picked/Aonsoku")
        XCTAssertEqual(fromCache.audioCacheDirectory.path, "/tmp/picked/Aonsoku/AudioCache")
        XCTAssertTrue(fromCache.isPicked)
        XCTAssertEqual(
            fromCache.accessURL.path, "/tmp/picked/Aonsoku/AudioCache",
            "access is requested for the folder the user chose"
        )
    }
}
#endif
