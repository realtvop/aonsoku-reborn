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
    /// A sign-in that waits for the user to keep or erase the library on
    /// this device. `session.account` is already the new account, but its
    /// stores do not run and the library is untouched until
    /// `confirmAccountSwitch()` or `keepLibraryData()`. `cancelAccountSwitch()`
    /// and `signOut()` drop the request. It survives a relaunch.
    public private(set) var pendingAccountSwitch: AccountSwitchRequest?
    public var isAwaitingAccountDecision: Bool { pendingAccountSwitch != nil }

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
    @ObservationIgnored private var smartDownloadsTask: Task<Void, Never>?
    @ObservationIgnored private var smartDownloadsGeneration: UInt64 = 0
    @ObservationIgnored private var smartDownloadsNeedFavoritesReload = false

    static let libraryOwnerStorageKey = "session.library-owner.v1"
    static let pendingAccountSwitchStorageKey = "session.pending-account-switch.v1"

    public convenience init(services: AppServices = .shared, bundle: Bundle = .main) {
        let api = LiveSubsonicAPI(
            transport: AuthenticatedSubsonicTransport(
                authentication: services.authentication
            )
        )
        self.init(
            services: services,
            bundle: bundle,
            network: NetworkMonitor(),
            api: api,
            sessionAuthenticationClient: nil
        )
    }

    init(
        services: AppServices,
        bundle: Bundle,
        network: NetworkMonitor,
        api: any SubsonicAPI,
        sessionAuthenticationClient: SessionAuthenticationClient?
    ) {
        self.services = services
        self.network = network
        toasts = ToastCenter()
        localizer = Localizer(bundle: bundle)
        settings = SettingsStore(preferences: services.preferences)
        self.api = api
        repository = LibraryRepository(
            api: api,
            library: services.library,
            connectivity: network.connectivity,
            serverType: { [authentication = services.authentication] in
                authentication.getCredentials()?.serverType
            }
        )
        artwork = ArtworkProvider(library: services.library)
        if let sessionAuthenticationClient {
            session = SessionStore(
                authentication: services.authentication,
                authenticationClient: sessionAuthenticationClient,
                preferences: services.preferences,
                api: api
            )
        } else {
            session = SessionStore(
                authentication: services.authentication,
                preferences: services.preferences,
                api: api
            )
        }
        sync = LibrarySyncStore(
            library: services.library,
            settings: settings,
            connectivity: network.connectivity
        )
        home = HomeStore(repository: repository, preferences: services.preferences)
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
        downloads.onAssetsCleared = { [weak artwork] in
            artwork?.purgeMemory()
        }
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
    /// the account's stores when signed in. A sign-in that was waiting for
    /// the user's decision when the app closed is restored as
    /// `pendingAccountSwitch` instead. Calling it again has no effect.
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
        guard let account = session.account else {
            services.preferences.remove(Self.pendingAccountSwitchStorageKey)
            return
        }
        do {
            try admit(account, explicitLogin: false)
        } catch {
            resetAccountStores()
            session.signOut()
            toasts.show(error: error)
        }
    }

    /// Signs in. The account's stores start right away when the library on
    /// this device is theirs or empty; otherwise `pendingAccountSwitch` is
    /// set and nothing starts or is erased until the user decides. A sign-in
    /// still waiting for a decision is dropped first, like an active session.
    public func signIn(
        serverUrl: String,
        fallbackUrl: String?,
        username: String,
        password: String
    ) async throws {
        if isActive || isAwaitingAccountDecision {
            signOut()
        }
        try await session.signIn(
            serverUrl: serverUrl,
            fallbackUrl: fallbackUrl,
            username: username,
            password: password
        )
        guard let account = session.account else { return }
        do {
            try admit(account, explicitLogin: true)
        } catch {
            session.signOut()
            throw error
        }
    }

    /// Erases the library, downloads and other data of the previous owner,
    /// records the pending account as the owner and starts its stores. If
    /// the erase fails the request stays pending and the error is rethrown,
    /// so it can be shown and retried. Does nothing without a request.
    public func confirmAccountSwitch() throws {
        guard let request = pendingAccountSwitch,
              let account = account(for: request) else { return }
        try eraseAccountData()
        try recordLibraryOwner(LibraryAccountIdentity(account: account))
        clearPendingAccountSwitch()
        resetAccountStores()
        activate()
    }

    /// Keeps the library on this device, records the pending account as its
    /// owner and starts its stores. Only allowed when the owner is unknown
    /// or has the same user name at another address; another user's library
    /// is never adopted, so `.differentAccount` throws
    /// `AccountSwitchError.libraryBelongsToAnotherAccount` and changes
    /// nothing. Does nothing without a request.
    public func keepLibraryData() throws {
        guard let request = pendingAccountSwitch else { return }
        if case .differentAccount = request.reason {
            throw AccountSwitchError.libraryBelongsToAnotherAccount
        }
        guard let account = account(for: request) else { return }
        try recordLibraryOwner(LibraryAccountIdentity(account: account))
        clearPendingAccountSwitch()
        resetAccountStores()
        activate()
    }

    /// Signs the pending account out. Nothing is erased and the recorded
    /// owner stays as it was.
    public func cancelAccountSwitch() {
        guard isAwaitingAccountDecision else { return }
        signOut()
    }

    /// Saves new server addresses for the signed-in account (see
    /// `SessionStore.updateServerUrls`). The credentials stay the same, so
    /// it is still the same account: when the library's recorded owner
    /// matched the account before the change, the new address is recorded
    /// as the owner and the library survives the next launch. A failed
    /// change is rethrown and leaves the owner alone. Throws
    /// `AccountSwitchError.decisionPending` while a sign-in waits for the
    /// user's decision.
    public func updateServerUrls(primaryUrl: String, fallbackUrl: String?) async throws {
        guard !isAwaitingAccountDecision else {
            throw AccountSwitchError.decisionPending
        }
        let before = session.account.map(LibraryAccountIdentity.init(account:))
        let owner = libraryOwner()
        try await session.updateServerUrls(primaryUrl: primaryUrl, fallbackUrl: fallbackUrl)
        guard let before, let owner, owner.isSameAccount(as: before),
              let account = session.account else { return }
        let updated = LibraryAccountIdentity(account: account)
        guard updated.isSameUsername(as: before) else { return }
        // If this write fails the address change still stands; the next
        // launch then asks whether to keep the library instead of erasing it.
        try? recordLibraryOwner(updated)
    }

    /// Stops playback and coordination and removes the credentials. The
    /// library and downloads stay on the device, as on the web. Also drops a
    /// pending account switch.
    public func signOut() {
        clearPendingAccountSwitch()
        activation?.cancel()
        activation = nil
        isActive = false
        smartDownloadsTask?.cancel()
        smartDownloadsTask = nil
        smartDownloadsGeneration &+= 1
        smartDownloadsNeedFavoritesReload = false
        smartDownloadsReady = false
        player.clearAll()
        downloads.stop()
        sync.stop()
        coordination.stop()
        resetAccountStores()
        session.signOut()
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
        if let account = session.account {
            let key = "\(account.primaryUrl.utf8.count):\(account.primaryUrl)\(account.username)"
            home.restoreCached(accountKey: key)
        }
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
            scheduleSmartDownloads(refreshFavorites: false)
            await session.refreshUser()
        }
    }

    /// Applies `accountSwitchDecision` to the signed-in account: records it
    /// as the library's owner and starts its stores, or leaves it pending
    /// for the user's decision. Never erases anything and records the owner
    /// only once the account may use the library.
    private func admit(_ account: ServerAccount, explicitLogin: Bool) throws {
        let identity = LibraryAccountIdentity(account: account)
        let owner = libraryOwner()
        resetAccountStores()
        if !explicitLogin,
           let restored = restoredPendingRequest(for: identity, owner: owner) {
            pendingAccountSwitch = restored
            return
        }
        pendingAccountSwitch = nil
        services.preferences.remove(Self.pendingAccountSwitchStorageKey)
        switch Self.accountSwitchDecision(
            previous: owner,
            next: identity,
            hasLibraryData: services.library.availability().available,
            explicitLogin: explicitLogin
        ) {
        case .adopt:
            try recordLibraryOwner(identity)
            activate()
        case .confirm(let reason):
            let request = AccountSwitchRequest(
                reason: reason,
                serverUrl: identity.serverUrl,
                username: identity.username
            )
            try services.preferences.setJSON(
                PendingAccountSwitchRecord(request),
                for: Self.pendingAccountSwitchStorageKey
            )
            pendingAccountSwitch = request
        }
    }

    /// What may happen when `next` signs in on a device whose library was
    /// recorded for `previous`. Never erases: the confirm cases wait for the
    /// user. Accounts match by normalized address and user name (see
    /// `LibraryAccountIdentity`).
    ///
    /// - A matching owner, or no owner and no library data: adopt.
    /// - No owner but library data: confirm `.unknownOwner` after an
    ///   explicit sign-in, adopt when restoring at launch.
    /// - The same user name at another server: confirm `.differentServer`.
    /// - Another user name: confirm `.differentAccount`.
    nonisolated static func accountSwitchDecision(
        previous: LibraryAccountIdentity?,
        next: LibraryAccountIdentity,
        hasLibraryData: Bool,
        explicitLogin: Bool
    ) -> AccountSwitchDecision {
        guard let previous else {
            return explicitLogin && hasLibraryData ? .confirm(.unknownOwner) : .adopt
        }
        if previous.isSameAccount(as: next) { return .adopt }
        if previous.isSameUsername(as: next) {
            return .confirm(.differentServer(previousServer: previous.serverUrl))
        }
        return .confirm(
            .differentAccount(
                previousServer: previous.serverUrl,
                previousUsername: previous.username
            )
        )
    }

    /// The request saved before the app closed, when it belongs to the
    /// restored account and the library still has another owner. A marker
    /// for another account, or one whose owner has since been recorded, is
    /// stale.
    private func restoredPendingRequest(
        for identity: LibraryAccountIdentity,
        owner: LibraryAccountIdentity?
    ) -> AccountSwitchRequest? {
        guard let record = services.preferences.getJSON(
            Self.pendingAccountSwitchStorageKey,
            as: PendingAccountSwitchRecord.self
        ),
            let request = record.request,
            record.identity.isSameAccount(as: identity),
            owner?.isSameAccount(as: identity) != true else { return nil }
        return request
    }

    /// The signed-in account that `request` was made for. When the session
    /// no longer has it, the app signs out rather than start anything.
    private func account(for request: AccountSwitchRequest) -> ServerAccount? {
        let requested = LibraryAccountIdentity(
            serverUrl: request.serverUrl,
            username: request.username
        )
        if let account = session.account,
           LibraryAccountIdentity(account: account).isSameAccount(as: requested) {
            return account
        }
        signOut()
        return nil
    }

    private func clearPendingAccountSwitch() {
        pendingAccountSwitch = nil
        services.preferences.remove(Self.pendingAccountSwitchStorageKey)
    }

    private func libraryOwner() -> LibraryAccountIdentity? {
        services.preferences.getJSON(
            Self.libraryOwnerStorageKey,
            as: LibraryAccountIdentity.self
        )
    }

    private func recordLibraryOwner(_ identity: LibraryAccountIdentity) throws {
        try services.preferences.setJSON(identity, for: Self.libraryOwnerStorageKey)
    }

    /// Removes the previous owner's server metadata, playback and history
    /// rows, audio and artwork caches, pins, lyrics selections and
    /// coordination registration, so the process-wide services cannot
    /// expose them to the next account.
    private func eraseAccountData() throws {
        player.clearAll()
        services.coordination.resetRegistration()
        try services.library.resetAccountData()
        _ = try services.audio.clearAudioFiles()
        services.preferences.remove("pinned.v1")
        services.preferences.remove(HomeStore.cacheKey)
        services.preferences.remove("lyrics.selections.v1")
        history.clear()
        artwork.purgeMemory()
    }

    private func resetAccountStores() {
        home.reset()
        pinned.reset()
        favorites.reset()
        playlists.reset()
        radios.reset()
        history.reset()
        lyrics.reset()
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
        downloads.reloadAfterLibrarySync()
        scheduleSmartDownloads(refreshFavorites: true)
    }

    private func applySmartDownloadsIfReady() {
        scheduleSmartDownloads(refreshFavorites: false)
    }

    private func scheduleSmartDownloads(refreshFavorites: Bool) {
        guard isActive, smartDownloadsReady else { return }
        if refreshFavorites {
            smartDownloadsNeedFavoritesReload = true
        }
        smartDownloadsGeneration &+= 1
        let generation = smartDownloadsGeneration
        smartDownloadsTask?.cancel()
        smartDownloadsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if smartDownloadsNeedFavoritesReload {
                await favorites.load()
                guard canApplySmartDownloads(generation: generation) else { return }
                smartDownloadsNeedFavoritesReload = false
            }
            await downloads.applySmartRules()
            guard canApplySmartDownloads(generation: generation) else { return }
            smartDownloadsTask = nil
        }
    }

    private func canApplySmartDownloads(generation: UInt64) -> Bool {
        !Task.isCancelled
            && isActive
            && smartDownloadsReady
            && smartDownloadsGeneration == generation
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
