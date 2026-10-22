import Foundation
import Observation

/// The app's composition root. Creates every store, connects them, and runs
/// the launch, sign-in and sign-out sequences. The SwiftUI app creates one
/// and puts it in the environment.
@MainActor
@Observable
public final class AppModel {
    /// `start()` has loaded settings, the language and the session.
    public private(set) var isStarted = false
    /// The signed-in account's stores are running.
    public private(set) var isActive = false

    @ObservationIgnored public let services: AppServices
    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored public let artwork: ArtworkProvider

    @ObservationIgnored public let network: NetworkMonitor
    @ObservationIgnored public let toasts: ToastCenter
    @ObservationIgnored public let localizer: Localizer
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public let session: SessionStore
    @ObservationIgnored public let sync: LibrarySyncStore
    @ObservationIgnored public let home: HomeStore
    @ObservationIgnored public let pinned: PinnedHomeStore
    @ObservationIgnored public let favorites: FavoritesStore
    @ObservationIgnored public let playlists: PlaylistsStore
    @ObservationIgnored public let radios: RadioStore
    @ObservationIgnored public let history: ListeningHistoryStore
    @ObservationIgnored public let player: PlayerStore
    @ObservationIgnored public let lyrics: LyricsStore
    @ObservationIgnored public let downloads: DownloadsStore
    @ObservationIgnored public let coordination: CoordinationStore

    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var smartDownloadsReady = false

    public init(services: AppServices = .shared, bundle: Bundle = .main) {
        self.services = services
        network = NetworkMonitor()
        toasts = ToastCenter()
        localizer = Localizer(bundle: bundle)
        settings = SettingsStore(preferences: services.preferences)
        api = LiveSubsonicAPI(
            transport: AuthenticatedSubsonicTransport(authentication: services.authentication)
        )
        repository = LibraryRepository(
            api: api,
            library: services.library,
            connectivity: network.connectivity,
            serverType: { [authentication = services.authentication] in
                authentication.getCredentials()?.serverType
            }
        )
        artwork = ArtworkProvider(library: services.library)
        session = SessionStore(
            authentication: services.authentication,
            preferences: services.preferences,
            api: api
        )
        sync = LibrarySyncStore(
            library: services.library,
            settings: settings,
            connectivity: network.connectivity
        )
        home = HomeStore(repository: repository)
        pinned = PinnedHomeStore(preferences: services.preferences, repository: repository)
        favorites = FavoritesStore(api: api, library: services.library)
        playlists = PlaylistsStore(repository: repository, api: api)
        radios = RadioStore(api: api)
        history = ListeningHistoryStore(preferences: services.preferences)
        player = PlayerStore(
            audio: services.audio,
            repository: repository,
            settings: settings,
            authentication: services.authentication
        )
        lyrics = LyricsStore(
            api: api,
            library: services.library,
            settings: settings,
            preferences: services.preferences
        )
        downloads = DownloadsStore(
            audio: services.audio,
            library: services.library,
            repository: repository,
            settings: settings
        )
        coordination = CoordinationStore(service: services.coordination, repository: repository)

        favorites.toasts = toasts
        downloads.favorites = favorites
        downloads.toasts = toasts
        coordination.toasts = toasts
        player.favorites = favorites
        player.remote = coordination
        lyrics.serverType = { [weak session] in session?.account?.serverType }
        settings.onChange { [weak self] old, new in
            self?.settingsChanged(from: old, to: new)
        }
        sync.onSyncCompleted { [weak self] in
            self?.librarySyncCompleted()
        }
    }

    // MARK: Lifecycle

    /// Migrates legacy settings, loads settings and the session, and starts
    /// the account's stores when signed in. Calling it again has no effect.
    public func start() {
        guard !isStarted else { return }
        SettingsMigration(preferences: services.preferences).run()
        settings.load()
        let current = settings.settings
        localizer.setLanguage(code: current.languageCode)
        history.maxSize = current.history.maxSize
        applyReplayGain(current.replayGain)
        network.start()
        session.restore()
        isStarted = true
        if session.isSignedIn {
            activate()
        }
    }

    /// Signs in and starts the account's stores.
    public func signIn(
        serverUrl: String,
        fallbackUrl: String?,
        username: String,
        password: String
    ) async throws {
        try await session.signIn(
            serverUrl: serverUrl,
            fallbackUrl: fallbackUrl,
            username: username,
            password: password
        )
        activate()
    }

    /// Stops playback and coordination and removes the credentials. The
    /// library and downloads stay on the device, as on the web.
    public func signOut() {
        activation?.cancel()
        activation = nil
        smartDownloadsReady = false
        player.clearAll()
        sync.stop()
        coordination.stop()
        session.signOut()
        isActive = false
    }

    /// The scene became active.
    public func didBecomeActive() {
        guard isActive else { return }
        sync.handleForeground()
    }

    /// The system is low on memory.
    public func didReceiveMemoryWarning() {
        artwork.purgeMemory()
    }

    private func activate() {
        guard !isActive else { return }
        isActive = true
        smartDownloadsReady = false
        services.library.initialize(startAutomaticSync: false)
        pinned.load()
        history.load()
        player.start()
        observePlayback()
        sync.start()
        coordination.start()
        activation = Task { [weak self] in
            guard let self else { return }
            let importer = LegacyWebDataImporter(
                library: services.library,
                preferences: services.preferences
            )
            if importer.isNeeded {
                _ = await importer.run()
            }
            guard !Task.isCancelled else { return }
            downloads.start()
            await favorites.load()
            guard !Task.isCancelled else { return }
            smartDownloadsReady = true
            await downloads.applySmartRules()
            guard !Task.isCancelled else { return }
            await session.refreshUser()
        }
    }

    // MARK: Connections

    /// Feeds play history from the player, re-registering after each change.
    private func observePlayback() {
        guard isActive else { return }
        let player = player
        withObservationTracking {
            _ = player.currentSong
            _ = player.isPlaying
            _ = player.target
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.playbackChanged()
            }
        }
    }

    private func playbackChanged() {
        guard isActive else { return }
        history.trackPlayback(
            song: player.currentSong,
            isPlaying: player.isPlaying,
            isRemote: player.target.isRemote
        )
        observePlayback()
    }

    private func settingsChanged(from old: AppSettings, to new: AppSettings) {
        if old.languageCode != new.languageCode {
            localizer.setLanguage(code: new.languageCode)
        }
        if old.replayGain != new.replayGain {
            applyReplayGain(new.replayGain)
        }
        if old.history.maxSize != new.history.maxSize {
            history.maxSize = new.history.maxSize
        }
        guard isActive else { return }
        if old.cache.assetsQuota != new.cache.assetsQuota || old.cache.lruQuota != new.cache.lruQuota {
            Task { await downloads.enforceQuotas() }
        }
        if old.cache.smartRules != new.cache.smartRules {
            applySmartDownloadsIfReady()
        }
        if old.lyrics != new.lyrics || old.privacy != new.privacy {
            Task { await lyrics.reload() }
        }
    }

    private func librarySyncCompleted() {
        applySmartDownloadsIfReady()
    }

    private func applySmartDownloadsIfReady() {
        guard isActive, smartDownloadsReady else { return }
        Task { await downloads.applySmartRules() }
    }

    private func applyReplayGain(_ replayGain: ReplayGainSettings) {
        services.audio.setReplayGain(
            replayGain.enabled
                ? AudioReplayGainConfig(
                    mode: replayGain.mode == .album ? .album : .track,
                    preAmp: replayGain.preAmp,
                    defaultGain: replayGain.defaultGain
                )
                : nil
        )
    }
}
