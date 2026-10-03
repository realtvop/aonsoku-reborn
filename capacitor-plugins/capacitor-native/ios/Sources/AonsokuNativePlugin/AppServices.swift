import Foundation

public final class AppServices: @unchecked Sendable {
    public static let shared = AppServices()

    public let audio: AudioService
    public let library: LibraryService
    public let lifecycle: AppLifecycleService

    private init() {
        audio = AudioService()
        library = LibraryService()
        lifecycle = AppLifecycleService(audio: audio)
    }
}
