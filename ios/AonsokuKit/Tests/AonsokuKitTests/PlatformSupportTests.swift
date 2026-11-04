import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AonsokuKit

final class ObservationTokenTests: XCTestCase {
    func testCancelRunsTheCancellationExactlyOnce() {
        let count = LockedTestBox(0)
        let token = ObservationToken { count.update { $0 += 1 } }

        token.cancel()
        token.cancel()

        XCTAssertEqual(count.read { $0 }, 1)
    }

    func testReleasingATokenCancelsIt() {
        let count = LockedTestBox(0)
        func observeAndDrop() {
            let token = ObservationToken { count.update { $0 += 1 } }
            _ = token
        }

        observeAndDrop()

        XCTAssertEqual(count.read { $0 }, 1)
    }

    func testCancellingBeforeReleaseDoesNotCancelTwice() {
        let count = LockedTestBox(0)
        func observeCancelAndDrop() {
            let token = ObservationToken { count.update { $0 += 1 } }
            token.cancel()
        }

        observeCancelAndDrop()

        XCTAssertEqual(count.read { $0 }, 1)
    }

    func testConcurrentCancellationsRunTheCancellationOnce() {
        let count = LockedTestBox(0)
        let token = ObservationToken { count.update { $0 += 1 } }

        DispatchQueue.concurrentPerform(iterations: 64) { _ in token.cancel() }

        XCTAssertEqual(count.read { $0 }, 1)
    }
}

final class ApplicationLifecycleTests: XCTestCase {
    func testPlatformNotificationsBecomeLifecycleEvents() {
        let center = NotificationCenter()
        let names = SystemApplicationLifecycle.notificationNames
        let events = LockedTestBox<[ApplicationLifecycleEvent]>([])
        let token = SystemApplicationLifecycle(center: center).observe { event in
            events.update { $0.append(event) }
        }

        center.post(name: names.background, object: nil)
        center.post(name: names.foreground, object: nil)
        center.post(name: names.background, object: nil)

        XCTAssertEqual(
            events.read { $0 },
            [.didEnterBackground, .willEnterForeground, .didEnterBackground]
        )
        token.cancel()
    }

    func testCancelledObservationStopsReceivingEvents() {
        let center = NotificationCenter()
        let names = SystemApplicationLifecycle.notificationNames
        let count = LockedTestBox(0)
        let token = SystemApplicationLifecycle(center: center).observe { _ in
            count.update { $0 += 1 }
        }

        token.cancel()
        center.post(name: names.background, object: nil)
        center.post(name: names.foreground, object: nil)

        XCTAssertEqual(count.read { $0 }, 0)
    }

    func testReleasedObservationStopsReceivingEvents() {
        let center = NotificationCenter()
        let names = SystemApplicationLifecycle.notificationNames
        let count = LockedTestBox(0)
        func observeAndDrop() {
            let token = SystemApplicationLifecycle(center: center).observe { _ in
                count.update { $0 += 1 }
            }
            _ = token
        }

        observeAndDrop()
        center.post(name: names.background, object: nil)

        XCTAssertEqual(count.read { $0 }, 0)
    }

    func testSeparateObservationsAreIndependent() {
        let center = NotificationCenter()
        let names = SystemApplicationLifecycle.notificationNames
        let lifecycle = SystemApplicationLifecycle(center: center)
        let first = LockedTestBox(0)
        let second = LockedTestBox(0)
        let firstToken = lifecycle.observe { _ in first.update { $0 += 1 } }
        let secondToken = lifecycle.observe { _ in second.update { $0 += 1 } }

        firstToken.cancel()
        center.post(name: names.background, object: nil)

        XCTAssertEqual(first.read { $0 }, 0)
        XCTAssertEqual(second.read { $0 }, 1)
        secondToken.cancel()
    }

    func testBackgroundAndForegroundUseDifferentNotifications() {
        let names = SystemApplicationLifecycle.notificationNames
        XCTAssertNotEqual(names.background, names.foreground)
    }

    #if os(macOS)
    func testAMacAppIsNeverTreatedAsBackgrounded() {
        // A Mac app keeps running and playing while another app is frontmost.
        XCTAssertFalse(PlatformApplication.isInBackground)
    }
    #endif
}

final class PlatformImageTests: XCTestCase {
    func testImageKeepsThePixelSizeOfItsBitmap() throws {
        let image = PlatformImage.make(cgImage: try Self.makeBitmap(width: 6, height: 4))

        XCTAssertEqual(image.size.width, 6)
        XCTAssertEqual(image.size.height, 4)
    }

    func testBitmapCanBeReadBackFromTheImage() throws {
        let image = PlatformImage.make(cgImage: try Self.makeBitmap(width: 6, height: 4))

        let bitmap = try XCTUnwrap(image.platformCGImage)

        XCTAssertEqual(bitmap.width, 6)
        XCTAssertEqual(bitmap.height, 4)
    }

    func testEncodedDataDecodesToAnImageOfTheSameSize() throws {
        let data = try Self.encodePNG(Self.makeBitmap(width: 8, height: 3))

        let image = try XCTUnwrap(PlatformImage(data: data))

        XCTAssertEqual(try XCTUnwrap(image.platformCGImage).width, 8)
        XCTAssertEqual(try XCTUnwrap(image.platformCGImage).height, 3)
    }

    func testInvalidDataDoesNotDecodeToAnImage() {
        XCTAssertNil(PlatformImage(data: Data("not an image".utf8)))
    }

    private static func makeBitmap(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
