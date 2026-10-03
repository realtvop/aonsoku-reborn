import Foundation

public final class AppServices: @unchecked Sendable {
    public static let shared = AppServices()

    public let audio: AudioService

    private init() {
        audio = AudioService()
    }
}
