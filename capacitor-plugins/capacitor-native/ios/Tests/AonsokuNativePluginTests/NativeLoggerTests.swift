import XCTest
@testable import AonsokuNativePlugin

final class NativeLoggerTests: XCTestCase {
    func testLoggerKeepsLevelsMessagesSourcesAndClockOrder() {
        let clock = AdvancingClock()
        let logger = NativeLogger(now: clock.now)

        logger.debug("debug", source: "one")
        logger.info("info", source: "two")
        logger.warn("warn")
        logger.error("error", source: "one")
        let entries = logger.getEntries()

        XCTAssertEqual(entries.map(\.level), [.debug, .info, .warn, .error])
        XCTAssertEqual(entries.map(\.message), ["debug", "info", "warn", "error"])
        XCTAssertEqual(entries.map(\.source), ["one", "two", "", "one"])
        XCTAssertEqual(entries.map(\.timestamp), entries.map(\.timestamp).sorted())
    }

    func testLoggerCapsEachSourceIndependently() {
        let logger = NativeLogger()
        for index in 0..<250 {
            logger.debug("heavy \(index)", source: "heavy")
        }
        logger.info("light", source: "light")

        let entries = logger.getEntries()

        XCTAssertEqual(entries.count, 201)
        XCTAssertFalse(entries.contains { $0.message == "heavy 0" })
        XCTAssertTrue(entries.contains { $0.message == "heavy 249" })
        XCTAssertTrue(entries.contains { $0.source == "light" })
    }

    func testLoggerClearRemovesAllBuckets() {
        let logger = NativeLogger()
        logger.info("one", source: "a")
        logger.info("two", source: "b")
        logger.clear()

        XCTAssertTrue(logger.getEntries().isEmpty)
    }
}

private final class AdvancingClock {
    private var value = Date(timeIntervalSince1970: 1_000)

    func now() -> Date {
        defer { value.addTimeInterval(1) }
        return value
    }
}
