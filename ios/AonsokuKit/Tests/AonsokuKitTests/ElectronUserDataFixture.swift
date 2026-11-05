import CryptoKit
import Foundation
import XCTest

@testable import AonsokuKit

/// What the Electron desktop app's `userData` folder looks like on disk,
/// written the way `electron/main/native/audio/cache.ts` writes it. No real
/// Electron-written files exist on the machines tests run on, so every test
/// that touches "Electron's folder" builds one of these in a temporary
/// directory (never in the real `~/Library/Application Support/Aonsoku`).
///
/// Layout (`<parent>/Application Support/Aonsoku`):
///
/// - `AudioCache/<base64url(songId)>.<ext>` and `<base64url(songId)>.json`
///   with `{"songId","fileName","contentType","lastModifiedAt"}` (compact
///   `JSON.stringify`, milliseconds);
/// - interrupted writes: `<fileName>.<pid>.<ms>.tmp` and
///   `<cacheId>.json.<pid>.<ms>.tmp`;
/// - the rest of `userData`: `store/*.json` (electron-store), `CoverCache/`,
///   `NativeAudio/` and Chromium's own files.
final class ElectronUserDataFixture {
    /// `<parent>/Application Support`: the directory a macOS layout under test
    /// uses as the user's Application Support, with Electron's folder in it.
    let applicationSupport: URL
    /// `<parent>/Application Support/Aonsoku`, Electron's `userData`.
    let root: URL

    var audioCache: URL { root.appendingPathComponent("AudioCache", isDirectory: true) }

    /// A song written to `AudioCache`.
    struct Song {
        let id: String
        let cacheId: String
        let audioURL: URL
        let metadataURL: URL
        let data: Data
        let contentType: String
        let lastModifiedAt: Int
    }

    init(parent: URL) throws {
        applicationSupport = parent.appendingPathComponent("Application Support", isDirectory: true)
        root = applicationSupport.appendingPathComponent("Aonsoku", isDirectory: true)
        let fileManager = FileManager.default
        for directory in [
            "store", "CoverCache", "AudioCache", "NativeAudio",
            "Local Storage/leveldb", "Cache/Cache_Data", "Session Storage",
        ] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // Everything else electron keeps there: contents never matter, only
        // that nothing in it changes.
        for (path, text) in [
            ("store/native-library.json", "{\"albums\":[],\"songs\":[]}"),
            ("store/credentials.json", "{\"value\":\"ENCRYPTED\"}"),
            ("store/preferences.json", "{\"theme\":\"dark\"}"),
            ("store/coordination.json", "{\"deviceId\":\"electron-device\"}"),
            ("CoverCache/Y292ZXI.jpg", "jpeg"),
            ("NativeAudio/playback-state.json", "{\"queue\":[]}"),
            ("Local Storage/leveldb/000003.log", "log"),
            ("Cache/Cache_Data/index", "index"),
            ("Preferences", "{}"),
            ("Local State", "{}"),
            ("Cookies", "cookies"),
        ] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
    }

    /// Audio bytes that differ per song, so a copy of another song's file is
    /// detectable.
    static func audioBytes(for id: String, size: Int = 4096) -> Data {
        var data = Data("ID3-\(id)-".utf8)
        var counter: UInt8 = 0
        while data.count < size {
            data.append(counter)
            counter &+= 31
        }
        return data.prefix(size)
    }

    /// Writes a song the way `storeAudioBuffer` does: audio, then metadata.
    @discardableResult
    func addSong(
        _ id: String,
        contentType: String = "audio/mpeg",
        size: Int = 4096,
        lastModifiedAt: Int = 1_700_000_000_000
    ) throws -> Song {
        let cacheId = AudioCacheUtils.cacheId(for: id)
        let fileName = "\(cacheId).\(AudioCacheUtils.fileExtension(for: contentType))"
        let data = Self.audioBytes(for: id, size: size)
        let audioURL = audioCache.appendingPathComponent(fileName)
        try data.write(to: audioURL)
        let metadataURL = audioCache.appendingPathComponent("\(cacheId).json")
        try writeMetadata(
            to: metadataURL,
            songId: id,
            fileName: fileName,
            contentType: contentType,
            lastModifiedAt: lastModifiedAt
        )
        return Song(
            id: id,
            cacheId: cacheId,
            audioURL: audioURL,
            metadataURL: metadataURL,
            data: data,
            contentType: contentType,
            lastModifiedAt: lastModifiedAt
        )
    }

    /// `JSON.stringify` of a `DesktopAudioCacheMetadata`: compact, in the
    /// declaration order of the interface.
    func writeMetadata(
        to url: URL,
        songId: String,
        fileName: String,
        contentType: String,
        lastModifiedAt: Int
    ) throws {
        let text = "{\"songId\":\(Self.jsonString(songId)),"
            + "\"fileName\":\(Self.jsonString(fileName)),"
            + "\"contentType\":\(Self.jsonString(contentType)),"
            + "\"lastModifiedAt\":\(lastModifiedAt)}"
        try Data(text.utf8).write(to: url)
    }

    /// The temporary audio file of a download that was interrupted before
    /// the rename.
    @discardableResult
    func addInterruptedDownload(_ id: String, ext: String = "mp3") throws -> URL {
        let cacheId = AudioCacheUtils.cacheId(for: id)
        let url = audioCache.appendingPathComponent("\(cacheId).\(ext).4242.1700000000123.tmp")
        try Self.audioBytes(for: id, size: 512).write(to: url)
        return url
    }

    /// The temporary metadata file of an interrupted `writeMetadata`.
    @discardableResult
    func addInterruptedMetadata(_ id: String) throws -> URL {
        let cacheId = AudioCacheUtils.cacheId(for: id)
        let url = audioCache.appendingPathComponent("\(cacheId).json.4242.1700000000123.tmp")
        try writeMetadata(
            to: url,
            songId: id,
            fileName: "\(cacheId).mp3",
            contentType: "audio/mpeg",
            lastModifiedAt: 1_700_000_000_000
        )
        return url
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    // MARK: Observing

    /// What `snapshot()` records about one entry.
    struct Entry: Equatable, CustomStringConvertible {
        let isDirectory: Bool
        let size: Int
        let permissions: Int
        let modified: Date?
        let digest: String

        var description: String {
            "\(isDirectory ? "dir" : "file") size=\(size) mode=\(String(permissions, radix: 8)) digest=\(digest.prefix(8)) mtime=\(modified?.timeIntervalSince1970 ?? 0)"
        }
    }

    /// Every entry below `root` with its type, size, permission bits,
    /// modification date and SHA-256 of its contents, so that "byte-identical"
    /// covers names, bytes, modes and times.
    func snapshot() throws -> [String: Entry] {
        try Self.snapshot(of: root)
    }

    static func snapshot(of root: URL) throws -> [String: Entry] {
        let fileManager = FileManager.default
        var entries: [String: Entry] = [:]
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(atPath: rootPath) else { return entries }
        for case let relative as String in enumerator {
            let path = (rootPath as NSString).appendingPathComponent(relative)
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let digest: String
            if isDirectory {
                digest = ""
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            entries[relative] = Entry(
                isDirectory: isDirectory,
                size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
                modified: attributes[.modificationDate] as? Date,
                digest: digest
            )
        }
        return entries
    }

    /// `chmod -R a-w`, as the importer tests require, undone at teardown so
    /// that the temporary directory can be removed.
    func makeReadOnly(for test: XCTestCase) throws {
        try Self.setWritable(false, at: root)
        test.addTeardownBlock { [root] in
            try? Self.setWritable(true, at: root)
        }
    }

    static func setWritable(_ writable: Bool, at root: URL) throws {
        let fileManager = FileManager.default
        var paths = [root.path]
        if let enumerator = fileManager.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                paths.append(root.appendingPathComponent(relative).path)
            }
        }
        // Directories last when making read-only (children first), first when
        // restoring (parents first), so that every change is permitted.
        let ordered = writable ? paths : paths.reversed()
        for path in ordered {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let current = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let mode = writable ? (current | 0o200) : (current & ~0o222)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }
}
