import Foundation
@testable import AonsokuKit

func makeSong(_ id: String, duration: Double = 180) -> QueueSong {
    QueueSong(
        id: id,
        title: "Song \(id)",
        artist: "Artist",
        album: "Album",
        duration: duration,
        streamUrl: "https://example.test/stream/\(id)"
    )
}

func makeSongRecord(_ id: String, title: String? = nil) -> SongRecord {
    SongRecord(
        id: id,
        parent: "album-1",
        title: title ?? "Song \(id)",
        album: "Album",
        artist: "Artist",
        track: nil,
        year: nil,
        genre: nil,
        coverArt: nil,
        size: nil,
        contentType: "audio/mpeg",
        suffix: "mp3",
        duration: 180,
        bitRate: nil,
        path: nil,
        playCount: nil,
        discNumber: nil,
        created: nil,
        albumId: "album-1",
        artistId: "artist-1",
        played: nil,
        starred: nil,
        starredAt: nil,
        playedAt: nil,
        bpm: nil,
        comment: nil,
        sortName: nil,
        mediaType: "song",
        musicBrainzId: nil,
        genresJson: nil,
        replayGainJson: nil
    )
}

func makeSilentWAVData(duration: Double = 0.05) -> Data {
    let samples = Data(
        repeating: 0,
        count: max(2, Int(16_000 * max(0, duration)))
    )
    let dataSize = UInt32(samples.count)
    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.appendLittleEndian(36 + dataSize)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(8_000))
    data.appendLittleEndian(UInt32(16_000))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    data.appendLittleEndian(dataSize)
    data.append(samples)
    return data
}

final class TemporaryDatabase {
    let directory: URL
    let manager: DatabaseManager

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aonsoku-ios-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        manager = try DatabaseManager(
            path: directory.appendingPathComponent("library.sqlite").path
        )
    }

    deinit {
        try? manager.dbPool.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

final class FakeSubsonicAPI: SubsonicAPI, @unchecked Sendable {
    var pingHandler: () async throws -> ServerInfo = { throw SubsonicAPIError.unsupported }
    var userHandler: (String) async throws -> SubsonicUser = { _ in
        throw SubsonicAPIError.unsupported
    }
    var scanStatusHandler: () async throws -> ScanStatus = {
        throw SubsonicAPIError.unsupported
    }
    var startScanHandler: () async throws -> ScanStatus = {
        throw SubsonicAPIError.unsupported
    }
    var albumListHandler: (
        AlbumListType,
        Int,
        Int,
        Int?,
        Int?,
        String?
    ) async throws -> [Album] = { _, _, _, _, _, _ in
        throw SubsonicAPIError.unsupported
    }
    var albumHandler: (String) async throws -> AlbumDetail = { _ in
        throw SubsonicAPIError.unsupported
    }
    var albumInfoHandler: (String) async throws -> AlbumInfo = { _ in
        throw SubsonicAPIError.unsupported
    }
    var artistsHandler: () async throws -> [Artist] = {
        throw SubsonicAPIError.unsupported
    }
    var artistHandler: (String) async throws -> ArtistDetail = { _ in
        throw SubsonicAPIError.unsupported
    }
    var artistInfoHandler: (String) async throws -> ArtistInfo = { _ in
        throw SubsonicAPIError.unsupported
    }
    var topSongsHandler: (String, Int) async throws -> [Song] = { _, _ in
        throw SubsonicAPIError.unsupported
    }
    var songHandler: (String) async throws -> Song = { _ in
        throw SubsonicAPIError.unsupported
    }
    var randomSongsHandler: (Int, String?, Int?, Int?) async throws -> [Song] = {
        _, _, _, _ in throw SubsonicAPIError.unsupported
    }
    var songsByGenreHandler: (String, Int, Int) async throws -> [Song] = {
        _, _, _ in throw SubsonicAPIError.unsupported
    }
    var genresHandler: () async throws -> [Genre] = {
        throw SubsonicAPIError.unsupported
    }
    var starredHandler: () async throws -> SearchResults = {
        throw SubsonicAPIError.unsupported
    }
    var searchHandler: (String, SearchPage) async throws -> SearchResults = {
        _, _ in throw SubsonicAPIError.unsupported
    }
    var playlistsHandler: () async throws -> [Playlist] = {
        throw SubsonicAPIError.unsupported
    }
    var playlistHandler: (String) async throws -> PlaylistDetail = { _ in
        throw SubsonicAPIError.unsupported
    }
    var createPlaylistHandler: (String, [String]) async throws -> PlaylistDetail? = {
        _, _ in throw SubsonicAPIError.unsupported
    }
    var updatePlaylistHandler: (String, PlaylistChanges) async throws -> Void = {
        _, _ in throw SubsonicAPIError.unsupported
    }
    var deletePlaylistHandler: (String) async throws -> Void = { _ in
        throw SubsonicAPIError.unsupported
    }
    var starHandler: (StarTarget) async throws -> Void = { _ in
        throw SubsonicAPIError.unsupported
    }
    var unstarHandler: (StarTarget) async throws -> Void = { _ in
        throw SubsonicAPIError.unsupported
    }
    var scrobbleHandler: (String, Bool, Date?) async throws -> Void = {
        _, _, _ in throw SubsonicAPIError.unsupported
    }
    var radioStationsHandler: () async throws -> [RadioStation] = {
        throw SubsonicAPIError.unsupported
    }
    var createRadioStationHandler: (String, String, String?) async throws -> Void = {
        _, _, _ in throw SubsonicAPIError.unsupported
    }
    var updateRadioStationHandler: (RadioStation) async throws -> Void = { _ in
        throw SubsonicAPIError.unsupported
    }
    var deleteRadioStationHandler: (String) async throws -> Void = { _ in
        throw SubsonicAPIError.unsupported
    }
    var lyricsHandler: (String, String) async throws -> SubsonicPlainLyrics? = {
        _, _ in throw SubsonicAPIError.unsupported
    }
    var lyricsBySongIdHandler: (String) async throws -> [SubsonicStructuredLyrics] = { _ in
        throw SubsonicAPIError.unsupported
    }

    func ping() async throws -> ServerInfo { try await pingHandler() }
    func user(username: String) async throws -> SubsonicUser { try await userHandler(username) }
    func scanStatus() async throws -> ScanStatus { try await scanStatusHandler() }
    func startScan() async throws -> ScanStatus { try await startScanHandler() }
    func albumList(
        _ type: AlbumListType,
        size: Int,
        offset: Int,
        fromYear: Int?,
        toYear: Int?,
        genre: String?
    ) async throws -> [Album] {
        try await albumListHandler(type, size, offset, fromYear, toYear, genre)
    }
    func album(id: String) async throws -> AlbumDetail { try await albumHandler(id) }
    func albumInfo(id: String) async throws -> AlbumInfo { try await albumInfoHandler(id) }
    func artists() async throws -> [Artist] { try await artistsHandler() }
    func artist(id: String) async throws -> ArtistDetail { try await artistHandler(id) }
    func artistInfo(id: String) async throws -> ArtistInfo { try await artistInfoHandler(id) }
    func topSongs(artistName: String, count: Int) async throws -> [Song] {
        try await topSongsHandler(artistName, count)
    }
    func song(id: String) async throws -> Song { try await songHandler(id) }
    func randomSongs(
        size: Int,
        genre: String?,
        fromYear: Int?,
        toYear: Int?
    ) async throws -> [Song] {
        try await randomSongsHandler(size, genre, fromYear, toYear)
    }
    func songsByGenre(_ genre: String, count: Int, offset: Int) async throws -> [Song] {
        try await songsByGenreHandler(genre, count, offset)
    }
    func genres() async throws -> [Genre] { try await genresHandler() }
    func starred() async throws -> SearchResults { try await starredHandler() }
    func search(_ query: String, page: SearchPage) async throws -> SearchResults {
        try await searchHandler(query, page)
    }
    func playlists() async throws -> [Playlist] { try await playlistsHandler() }
    func playlist(id: String) async throws -> PlaylistDetail { try await playlistHandler(id) }
    func createPlaylist(name: String, songIds: [String]) async throws -> PlaylistDetail? {
        try await createPlaylistHandler(name, songIds)
    }
    func updatePlaylist(id: String, changes: PlaylistChanges) async throws {
        try await updatePlaylistHandler(id, changes)
    }
    func deletePlaylist(id: String) async throws { try await deletePlaylistHandler(id) }
    func star(_ target: StarTarget) async throws { try await starHandler(target) }
    func unstar(_ target: StarTarget) async throws { try await unstarHandler(target) }
    func scrobble(songId: String, submission: Bool, time: Date?) async throws {
        try await scrobbleHandler(songId, submission, time)
    }
    func radioStations() async throws -> [RadioStation] { try await radioStationsHandler() }
    func createRadioStation(
        name: String,
        streamUrl: String,
        homePageUrl: String?
    ) async throws {
        try await createRadioStationHandler(name, streamUrl, homePageUrl)
    }
    func updateRadioStation(_ station: RadioStation) async throws {
        try await updateRadioStationHandler(station)
    }
    func deleteRadioStation(id: String) async throws {
        try await deleteRadioStationHandler(id)
    }
    func lyrics(artist: String, title: String) async throws -> SubsonicPlainLyrics? {
        try await lyricsHandler(artist, title)
    }
    func lyricsBySongId(_ id: String) async throws -> [SubsonicStructuredLyrics] {
        try await lyricsBySongIdHandler(id)
    }
}

final class LockedTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read<T>(_ body: (Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

func makeIsolatedScrobbleBuffer() -> NativeScrobbleBuffer {
    NativeScrobbleBuffer(store: IsolatedScrobbleEntryStore())
}

func makeIsolatedScrobbleSubmitter() -> NativeScrobbleSubmitter {
    NativeScrobbleSubmitter(
        credentialsProvider: { nil },
        request: { _, _, _, _ in false }
    )
}

private final class IsolatedScrobbleEntryStore: ScrobbleEntryStore {
    func load() -> [ScrobbleEntry] { [] }
    func save(_: [ScrobbleEntry]) {}
}

// MARK: - Data Conversion Helpers (from removed AonsokuNativeDataPlugin)

func pageDictionary<T: Encodable & Sendable>(_ page: LibraryPage<T>) -> [String: Any] {
    [
        "items": page.items.map(dictionary),
        "total": page.total,
        "hasMore": page.hasMore,
    ]
}

func dictionary<T: Encodable>(_ value: T) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        return [:]
    }
    return dictionary
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
