import Foundation
import XCTest

/// Keeps platform-specific code behind the abstractions in `Platform/`. A use
/// anywhere else either breaks one platform's build or quietly skips the other
/// platform's behavior.
final class PlatformBoundaryTests: XCTestCase {
    /// Frameworks, symbols and conditions that belong to one platform.
    private static let platformSpecific = [
        "import UIKit", "import AppKit", "import BackgroundTasks", "import CTailscale",
        "UIApplication", "NSApplication", "AVAudioSession", "MPVolumeView",
        "BGTaskScheduler", "NSBackgroundActivityScheduler",
        "os(iOS)", "os(macOS)",
        "canImport(UIKit)", "canImport(AppKit)", "canImport(CTailscale)",
    ]

    /// The abstractions themselves, and the debug screen, which is UIKit-only
    /// and compiled out on macOS.
    private static let allowedFolders: Set<String> = ["Platform", "Debug"]

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPlatformSpecificCodeStaysInsideThePlatformFolder() throws {
        let sources = packageRoot.appendingPathComponent("Sources/AonsokuKit")
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var checked = 0

        for case let file as URL in files where file.pathExtension == "swift" {
            let folder = file.deletingLastPathComponent().lastPathComponent
            guard !Self.allowedFolders.contains(folder) else { continue }
            checked += 1

            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for symbol in Self.platformSpecific where code.contains(symbol) {
                XCTFail(
                    "\(file.lastPathComponent) uses \(symbol) directly; "
                        + "reach it through an abstraction in Platform/ instead"
                )
            }
        }
        XCTAssertGreaterThan(checked, 20, "The scan found too few source files")
    }

    func testPlatformFolderExists() {
        let folder = packageRoot.appendingPathComponent("Sources/AonsokuKit/Platform")
        var isDirectory: ObjCBool = false

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testThePackageSupportsMacOSAndLinksTailscaleOnlyOnIOS() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains(".macOS(.v15)"))
        XCTAssertTrue(manifest.contains(".iOS(.v16)"))
        // The libtailscale archive has no macOS slice, so macOS builds omit it
        // and `TailscaleSupport` reports the node unavailable.
        XCTAssertTrue(
            manifest.contains(
                #".target(name: "CTailscale", condition: .when(platforms: [.iOS]))"#
            )
        )
    }
}
