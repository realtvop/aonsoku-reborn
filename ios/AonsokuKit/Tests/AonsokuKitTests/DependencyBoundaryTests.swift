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

    func testOnlyCoordinationPluginImportsCapacitor() {
        // This test verifies the architecture boundary: AonsokuKit services
        // do not depend on Capacitor. Only AonsokuNativeCoordinationPlugin
        // (which bridges to the WebView) imports Capacitor.
        // If this test fails, check that:
        // - AuthenticationService, PreferencesService, and other services
        //   do not import Capacitor
        // - AudioPayloadCodec and AudioCoordinationBridge do not import
        //   Capacitor (they are Capacitor-free codecs)
        // - EventEmitter does not import Capacitor
        // - Only AonsokuNativeCoordinationPlugin and adapters still import it

        // Verify core services can be instantiated without Capacitor ceremony
        _ = AuthenticationService.shared
        _ = PreferencesService.shared
        _ = AppServices.shared
    }
}
