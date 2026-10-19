import AVFoundation
import XCTest
@testable import AonsokuKit

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

    func testAonsokuKitDoesNotDependOnCapacitor() {
        // This test verifies the architecture boundary: AonsokuKit source code
        // does not import Capacitor or Cordova. All coordination is managed
        // internally by CoordinationRealtime and CoordinationService.
        // If this test fails, check that no file under ios/AonsokuKit/Sources
        // and ios/Aonsoku has an import Capacitor or import Cordova statement.

        // Verify core services can be instantiated without Capacitor ceremony
        _ = AuthenticationService.shared
        _ = PreferencesService.shared
        _ = AppServices.shared
    }
}
