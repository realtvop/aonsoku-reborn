import AVFoundation
import XCTest
@testable import AonsokuNativePlugin

final class DependencyBoundaryTests: XCTestCase {
    func testAudioServiceUsesInjectedPlayerFactory() throws {
        let database = try TemporaryDatabase()
        let audioURL = database.directory.appendingPathComponent("fixture.wav")
        try makeSilentWAVData().write(to: audioURL)
        var factoryCalls = 0
        let service = AudioService(
            databaseManager: database.manager,
            playerFactory: { item in
                factoryCalls += 1
                return AVPlayer(playerItem: item)
            }
        )

        service.load(AudioLoadRequest(
            source: .nativeFile(uri: audioURL.absoluteString, songId: "fixture")
        )) { _ in }

        XCTAssertEqual(factoryCalls, 1)
        service.clear()
    }
}
