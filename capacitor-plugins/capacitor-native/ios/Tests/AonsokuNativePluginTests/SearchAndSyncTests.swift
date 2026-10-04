import XCTest
@testable import AonsokuNativePlugin

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
}
