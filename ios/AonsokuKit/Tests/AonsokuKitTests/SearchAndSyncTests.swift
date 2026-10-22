import XCTest
@testable import AonsokuKit

final class SearchAndSyncTests: XCTestCase {
    func testSearchTokenizationNormalizesCaseWidthAndDiacritics() {
        XCTAssertEqual(SearchHelper.tokenize("Café RÉSUMÉ"), ["cafe", "resume"])
        XCTAssertEqual(SearchHelper.tokenize("  "), [])
    }

    func testRepositorySearchRequiresEveryTokenAcrossAvailableColumns() throws {
        let database = try TemporaryDatabase()
        let repository = ArtistRepository(db: database.manager.dbPool)
        try repository.bulkUpsert([
            ArtistRecord(
                id: "1",
                name: "Beyoncé Knowles",
                albumCount: 1,
                coverArt: nil,
                artistImageUrl: nil,
                starred: nil,
                starredAt: nil,
                musicBrainzId: nil,
                sortName: nil
            ),
            ArtistRecord(
                id: "2",
                name: "Beyonce Covers",
                albumCount: 1,
                coverArt: nil,
                artistImageUrl: nil,
                starred: nil,
                starredAt: nil,
                musicBrainzId: nil,
                sortName: nil
            ),
        ])

        let result = try repository.getAll(
            limit: 10,
            offset: 0,
            filter: ArtistQueryFilter(
                search: "beyonce knowles",
                starredOnly: nil,
                sortBy: nil,
                sortOrder: nil
            )
        )

        XCTAssertEqual(result.items.map(\.id), ["1"])
    }

    func testFullLibrarySearchQueryMatchesServerDialect() {
        XCTAssertEqual(buildAllSongsQuery(serverType: "navidrome"), "\"\"")
        XCTAssertEqual(buildAllSongsQuery(serverType: "subsonic"), "")
        XCTAssertEqual(buildAllSongsQuery(serverType: "gonic"), "")
        XCTAssertEqual(buildAllSongsQuery(serverType: ""), "")
    }

    func testSyncFreshnessUsesStrictBoundaryAndHandlesClockSkew() {
        let now = 10_000_000
        for tier in SyncTier.allCases {
            XCTAssertTrue(tier.isFresh(
                lastSyncedAtMs: now - tier.freshWindowMs + 1,
                nowMs: now
            ))
            XCTAssertFalse(tier.isFresh(
                lastSyncedAtMs: now - tier.freshWindowMs,
                nowMs: now
            ))
            XCTAssertTrue(tier.isFresh(lastSyncedAtMs: now + 1, nowMs: now))
        }
        XCTAssertLessThan(SyncTier.t1.freshWindowMs, SyncTier.t2.freshWindowMs)
        XCTAssertLessThan(SyncTier.t2.freshWindowMs, SyncTier.t3.freshWindowMs)
    }

    func testCachedSongReconciliationUsesDeletionSafetyAndRestoresSongs() throws {
        let database = try TemporaryDatabase()
        let cache = CacheMetaRepository(db: database.manager.dbPool)
        try cache.bulkUpsert([
            cacheRow(id: "present", removed: true),
            cacheRow(id: "missing", removed: false),
        ])
        let engine = SyncEngine(
            db: database.manager.dbPool,
            httpClient: SearchSyncHTTPClient(),
            credentialsProvider: { nil }
        )

        try engine.reconcileCachedSongs(
            serverIds: ["present"],
            staleSongCount: 2,
            serverSongCount: 10
        )
        var rows = Dictionary(uniqueKeysWithValues: try cache.getAll(type: "audio").map {
            ($0.id, $0)
        })
        XCTAssertEqual(rows["present"]?.removedFromServer, false)
        XCTAssertEqual(rows["missing"]?.removedFromServer, false)

        try engine.reconcileCachedSongs(
            serverIds: ["present"],
            staleSongCount: 1,
            serverSongCount: 10
        )
        rows = Dictionary(uniqueKeysWithValues: try cache.getAll(type: "audio").map {
            ($0.id, $0)
        })
        XCTAssertEqual(rows["missing"]?.removedFromServer, true)

        try engine.reconcileCachedSongs(
            serverIds: ["present", "missing"],
            staleSongCount: 0,
            serverSongCount: 10
        )
        XCTAssertEqual(
            try cache.getByKey("audio:missing")?.removedFromServer,
            false
        )
    }

    private func cacheRow(id: String, removed: Bool) -> CacheMetaRecord {
        CacheMetaRecord(
            key: "audio:\(id)",
            id: id,
            type: "audio",
            source: "explicit",
            triggersJson: nil,
            coverSize: nil,
            sizeBytes: 1,
            cachedAt: 1,
            lastAccessedAt: 1,
            removedFromServer: removed
        )
    }
}

private struct SearchSyncHTTPClient: LibrarySyncHTTPClient {
    func request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: [String: String],
        method: String
    ) async throws -> SubsonicResponse {
        throw SubsonicAPIError.unsupported
    }
}
