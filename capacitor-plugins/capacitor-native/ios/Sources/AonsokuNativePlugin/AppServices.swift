import Foundation

public final class AppServices: @unchecked Sendable {
    public static let shared = AppServices()

    public let audio: AudioService
    public let library: LibraryService
    public let lifecycle: AppLifecycleService

    private convenience init() {
        self.init(audio: AudioService(), library: LibraryService())
    }

    init(
        audio: AudioService,
        library: LibraryService,
        lifecycleFactory: (AudioService) -> AppLifecycleService = {
            AppLifecycleService(audio: $0)
        }
    ) {
        self.audio = audio
        self.library = library
        self.lifecycle = lifecycleFactory(audio)
    }
}
