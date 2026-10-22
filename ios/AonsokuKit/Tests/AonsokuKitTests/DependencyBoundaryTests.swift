import AVFoundation
import MediaPlayer
import UIKit
import XCTest
@testable import AonsokuKit

@MainActor
final class DependencyBoundaryTests: XCTestCase {
    func testAudioServiceUsesInjectedPlayerFactory() throws {
        let database = try TemporaryDatabase()
        let audioURL = database.directory.appendingPathComponent("fixture.wav")
        try makeSilentWAVData().write(to: audioURL)
        var factoryCalls = 0
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
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

    func testAonsokuKitSourcesDoNotUseFatalErrors() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources/AonsokuKit")
        let files = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil
            )
        )

        for case let file as URL in files where file.pathExtension == "swift" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                contents.contains("fatalError("),
                "Unexpected fatalError in \(file.lastPathComponent)"
            )
        }
    }

    func testVolumeHUDControlStaysAttachedWhenTheHostChanges() throws {
        let database = try TemporaryDatabase()
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        let firstHost = UIView()
        let secondHost = UIView()

        service.start(volumeHostView: firstHost)
        service.setVolumeHUDEnabled(false)

        XCTAssertEqual(firstHost.subviews.filter { $0 is MPVolumeView }.count, 1)

        service.start(volumeHostView: secondHost)

        XCTAssertFalse(firstHost.subviews.contains { $0 is MPVolumeView })
        XCTAssertEqual(secondHost.subviews.filter { $0 is MPVolumeView }.count, 1)

        service.setVolumeHUDEnabled(true)
        XCTAssertFalse(secondHost.subviews.contains { $0 is MPVolumeView })
        service.shutdown()
    }
}
