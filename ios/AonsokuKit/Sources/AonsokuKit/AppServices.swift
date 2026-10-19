import Foundation

public final class AppServices: @unchecked Sendable {
    public static let shared = AppServices()

    public let audio: AudioService
    public let library: LibraryService
    public let lifecycle: AppLifecycleService
    public let authentication: AuthenticationService
    public let preferences: PreferencesService

    private convenience init() {
        self.init(audio: AudioService(), library: LibraryService())
    }

    init(
        audio: AudioService,
        library: LibraryService,
        authentication: AuthenticationService = .shared,
        preferences: PreferencesService = .shared,
        lifecycleFactory: (AudioService) -> AppLifecycleService = {
            AppLifecycleService(audio: $0)
        }
    ) {
        self.audio = audio
        self.library = library
        self.authentication = authentication
        self.preferences = preferences
        self.lifecycle = lifecycleFactory(audio)
    }
}
