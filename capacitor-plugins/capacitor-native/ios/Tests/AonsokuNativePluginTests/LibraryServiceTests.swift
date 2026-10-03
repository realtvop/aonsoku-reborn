import XCTest
@testable import AonsokuNativePlugin

final class LibraryServiceTests: XCTestCase {
    func testTypedArtistQueryFiltersAndPaginatesRepositoryData() throws {
        let database = try TemporaryDatabase()
        let repository = ArtistRepository(db: database.manager.dbPool)
        try repository.bulkUpsert([
            ArtistRecord(
                id: "1",
                name: "Alpha Artist",
                albumCount: 2,
                coverArt: nil,
                artistImageUrl: nil,
                starred: "2026-01-01",
                starredAt: 20,
                musicBrainzId: nil,
                sortName: nil
            ),
            ArtistRecord(
                id: "2",
                name: "Beta Artist",
                albumCount: 1,
                coverArt: nil,
                artistImageUrl: nil,
                starred: nil,
                starredAt: nil,
                musicBrainzId: nil,
                sortName: nil
            ),
            ArtistRecord(
                id: "3",
                name: "Alpha Two",
                albumCount: 3,
                coverArt: nil,
                artistImageUrl: nil,
                starred: "2026-01-02",
                starredAt: 10,
                musicBrainzId: nil,
                sortName: nil
            ),
        ])
        let service = LibraryService(dbManager: database.manager)

        let page = try service.artists(
            limit: 1,
            offset: 0,
            filter: LibraryArtistFilter(
                search: "alpha",
                starredOnly: true,
                sortBy: "starredAt",
                sortOrder: "desc"
            )
        )

        XCTAssertEqual(page.total, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.map(\.id), ["1"])
        XCTAssertEqual(page.items.first?.name, "Alpha Artist")
    }
}
