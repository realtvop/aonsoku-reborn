import Foundation

public final class AppServices: @unchecked Sendable {
    public static let shared = AppServices()

    public let audio: AudioService
    public let library: LibraryService

    private init() {
        audio = AudioService()
        library = LibraryService()
    }
}
