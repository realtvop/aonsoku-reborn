import Foundation

/// How this build names its platform to the coordination server, and through
/// it to the device list of every other client.
///
/// The server stores the string as given, and the web picks a device's icon by
/// what it contains (`ios` → phone, `mac` → laptop), so a new platform needs a
/// name that keeps working there.
enum PlatformDevice {
    /// What the native iOS app has registered as since it replaced the
    /// Capacitor one. Existing registrations carry it, and the web names its
    /// own iOS runtime the same way.
    static let iOSCoordinationPlatform = "capacitor-ios"

    /// The native Mac app. It is a device of its own, apart from the Electron
    /// desktop app (`electron`) that may run on the same Mac.
    static let macOSCoordinationPlatform = "macos"

    /// The platform this build registers with.
    static var coordinationPlatform: String {
        #if canImport(UIKit)
        iOSCoordinationPlatform
        #else
        macOSCoordinationPlatform
        #endif
    }
}
