import XCTest
@testable import AonsokuNativePlugin

final class ShuffleTests: XCTestCase {
    func testShuffleKeepsPermutationAndMovesRecentHistoryBehindFreshSongs() {
        let engine = NativeShuffleEngine()
        let songs = [makeSong("1"), makeSong("2"), makeSong("3")]

        let shuffled = engine.shuffleWithGapAvoidance(songs, history: ["2"])

        XCTAssertEqual(Set(shuffled.map(\.id)), Set(songs.map(\.id)))
        XCTAssertEqual(shuffled.last?.id, "2")
    }

    func testPushToHistoryDeduplicatesAndBoundsOldestEntries() {
        let engine = NativeShuffleEngine()

        XCTAssertEqual(
            engine.pushToHistory(["1", "2"], id: "2", maxLen: 3),
            ["1", "2"]
        )
        XCTAssertEqual(
            engine.pushToHistory(["1", "2", "3"], id: "4", maxLen: 3),
            ["2", "3", "4"]
        )
    }

    func testRandomStartAvoidsRecentIdsWhenFreshCandidateExists() {
        let engine = NativeShuffleEngine()
        let ids = ["old-1", "fresh", "old-2"]

        let index = engine.pickRandomStartIndex(
            count: ids.count,
            startHistory: ["old-1", "old-2"],
            getId: { ids[$0] }
        )

        XCTAssertEqual(ids[index], "fresh")
        XCTAssertEqual(
            engine.pickRandomStartIndex(count: 0, startHistory: [], getId: { _ in "" }),
            0
        )
    }
}
