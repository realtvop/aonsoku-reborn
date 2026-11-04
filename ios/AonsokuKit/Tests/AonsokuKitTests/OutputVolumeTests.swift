import XCTest
@testable import AonsokuKit

final class AppVolumeControlTests: XCTestCase {
    func testStartsAtFullVolumeWithoutReducingThePlayer() throws {
        let control = AppVolumeControl(defaults: try makeDefaults())

        XCTAssertEqual(control.volume, 1)
        XCTAssertEqual(control.playerGain, 1)
    }

    func testSettingTheVolumeReportsItAndScalesThePlayer() throws {
        let control = AppVolumeControl(defaults: try makeDefaults())

        XCTAssertEqual(try set(control, 0.4), 0.4)

        XCTAssertEqual(control.volume, 0.4)
        XCTAssertEqual(control.playerGain, 0.4)
    }

    func testVolumeIsClampedToTheUnitRange() throws {
        let control = AppVolumeControl(defaults: try makeDefaults())

        XCTAssertEqual(try set(control, 2), 1)
        XCTAssertEqual(control.volume, 1)
        XCTAssertEqual(try set(control, -3), 0)
        XCTAssertEqual(control.volume, 0)
        XCTAssertEqual(control.playerGain, 0)
    }

    func testNotANumberFallsBackToFullVolume() throws {
        let control = AppVolumeControl(defaults: try makeDefaults())
        _ = try set(control, 0.2)

        XCTAssertEqual(try set(control, .nan), 1)
        XCTAssertEqual(control.volume, 1)
    }

    func testVolumeSurvivesRecreation() throws {
        let defaults = try makeDefaults()
        _ = try set(AppVolumeControl(defaults: defaults), 0.25)

        let restored = AppVolumeControl(defaults: defaults)

        XCTAssertEqual(restored.volume, 0.25)
        XCTAssertEqual(restored.playerGain, 0.25)
    }

    func testSeparatePreferenceStoresDoNotShareAVolume() throws {
        let first = AppVolumeControl(defaults: try makeDefaults())
        let second = AppVolumeControl(defaults: try makeDefaults())

        _ = try set(first, 0.1)

        XCTAssertEqual(second.volume, 1)
    }

    func testStoredValuesOutsideTheRangeAreClamped() throws {
        let defaults = try makeDefaults()
        defaults.set(7.5, forKey: AppVolumeControl.defaultsKey)
        XCTAssertEqual(AppVolumeControl(defaults: defaults).volume, 1)

        defaults.set(-2.0, forKey: AppVolumeControl.defaultsKey)
        XCTAssertEqual(AppVolumeControl(defaults: defaults).volume, 0)
    }

    func testUnreadableStoredValueFallsBackToFullVolume() throws {
        let defaults = try makeDefaults()
        defaults.set("loud", forKey: AppVolumeControl.defaultsKey)

        XCTAssertEqual(AppVolumeControl(defaults: defaults).volume, 1)
    }

    func testTheVolumeIsReadableFromAnyThread() async throws {
        let control = AppVolumeControl(defaults: try makeDefaults())
        _ = try set(control, 0.6)

        let volume = await Task.detached { control.volume }.value

        XCTAssertEqual(volume, 0.6)
    }

    func testOnlyTheAppMovesItsOwnVolume() throws {
        let control = AppVolumeControl(defaults: try makeDefaults())
        let reported = LockedTestBox<[Float]>([])
        control.startObserving { value in reported.update { $0.append(value) } }

        _ = try set(control, 0.3)
        control.setHUDEnabled(false)
        control.setHostView(nil)
        control.stopObserving()

        // The result of `set` is reported to its caller, not to the observer.
        XCTAssertEqual(reported.read { $0 }, [])
        XCTAssertEqual(control.volume, 0.3)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "aonsoku-app-volume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @discardableResult
    private func set(_ control: AppVolumeControl, _ value: Float) throws -> Float {
        var outcome: Result<Float, AudioServiceError>?
        control.set(value) { outcome = $0 }
        return try XCTUnwrap(outcome).get()
    }
}
