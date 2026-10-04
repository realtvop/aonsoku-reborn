import AVFoundation
import XCTest
@testable import AonsokuNativePlugin

final class DependencyBoundaryTests: XCTestCase {
    func testAudioServiceUsesInjectedPlayerFactory() throws {
        let database = try TemporaryDatabase()
        let audioURL = database.directory.appendingPathComponent("fixture.wav")
        try makeSilentWAV().write(to: audioURL)
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

private func makeSilentWAV() -> Data {
    let samples = Data(repeating: 0, count: 800)
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

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
