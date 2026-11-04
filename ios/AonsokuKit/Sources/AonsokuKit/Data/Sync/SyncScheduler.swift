import Foundation

public final class SyncScheduler {
    public static let bgTaskIdentifier = "github.realtvop.aonsoku.sync.refresh"

    /// The earliest the next background refresh may start after a request.
    static let backgroundRefreshInterval: TimeInterval = 30 * 60

    private static var shared: SyncScheduler?

    /// `register()` and every scheduler share one platform scheduler, so the
    /// handler installed at launch is the one that receives later requests.
    static let platformBackgroundRefresh = PlatformBackgroundRefresh
        .makeScheduler(identifier: bgTaskIdentifier)

    private let syncEngine: SyncEngine
    private let backgroundRefresh: BackgroundRefreshScheduling
    private var lifecycleObservation: ObservationToken?
    private var foregroundTimer: Timer?
    private var isInForeground = true
    private(set) var isForegroundSchedulingEnabled = false

    /// Whether the periodic foreground sync is currently ticking.
    var isForegroundTimerRunning: Bool { foregroundTimer != nil }

    init(
        syncEngine: SyncEngine,
        lifecycle: ApplicationLifecycleObserving = SystemApplicationLifecycle(),
        backgroundRefresh: BackgroundRefreshScheduling = SyncScheduler.platformBackgroundRefresh
    ) {
        self.syncEngine = syncEngine
        self.backgroundRefresh = backgroundRefresh
        Self.shared = self
        observeAppLifecycle(lifecycle)
    }

    func setForegroundSchedulingEnabled(_ enabled: Bool) {
        isForegroundSchedulingEnabled = enabled
        guard enabled, isInForeground else {
            stopForegroundSchedule()
            return
        }
        startForegroundSchedule()
    }

    private func startForegroundSchedule() {
        guard isForegroundSchedulingEnabled else { return }
        stopForegroundSchedule()
        isInForeground = true
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: SyncTier.t1.freshWindowSeconds, repeats: true) { [weak self] _ in
            self?.syncEngine.syncIncremental()
        }
    }

    func stopForegroundSchedule() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    func triggerImmediateSync() {
        syncEngine.syncAll()
    }

    // MARK: - Background Refresh

    /// Installs the background refresh handler. Call it before the app
    /// finishes launching: iOS rejects registrations made afterwards.
    public static func register() {
        register(on: platformBackgroundRefresh)
    }

    static func register(on scheduler: BackgroundRefreshScheduling) {
        scheduler.register { task in
            if let shared = Self.shared {
                shared.handleBackgroundRefresh(task)
            } else {
                let db = DatabaseManager.shared.dbPool
                let httpClient = SubsonicHTTPClient()
                let syncEngine = SyncEngine(db: db, httpClient: httpClient)

                // Schedule next background refresh
                scheduler.schedule(after: backgroundRefreshInterval)

                let syncTask = Task {
                    await syncEngine.syncAllAndWait(
                        includeFullSongs: false,
                        mode: "incremental"
                    )
                }

                task.expirationHandler = {
                    syncEngine.cancel()
                    syncTask.cancel()
                }

                Task {
                    let succeeded = await syncTask.value
                    task.setCompleted(success: succeeded)
                }
            }
        }
    }

    func scheduleNextBackgroundRefresh() {
        backgroundRefresh.schedule(after: Self.backgroundRefreshInterval)
    }

    func handleBackgroundRefresh(_ task: BackgroundRefreshTask) {
        scheduleNextBackgroundRefresh()

        let syncTask = Task {
            await syncEngine.syncAllAndWait(
                includeFullSongs: false,
                mode: "incremental"
            )
        }

        task.expirationHandler = { [weak self] in
            self?.syncEngine.cancel()
            syncTask.cancel()
        }

        Task {
            let succeeded = await syncTask.value
            task.setCompleted(success: succeeded)
        }
    }

    // MARK: - App Lifecycle

    private func observeAppLifecycle(_ lifecycle: ApplicationLifecycleObserving) {
        lifecycleObservation = lifecycle.observe { [weak self] event in
            switch event {
            case .didEnterBackground: self?.appDidEnterBackground()
            case .willEnterForeground: self?.appWillEnterForeground()
            }
        }
    }

    func appDidEnterBackground() {
        isInForeground = false
        stopForegroundSchedule()
        scheduleNextBackgroundRefresh()
    }

    func appWillEnterForeground() {
        isInForeground = true
        guard isForegroundSchedulingEnabled else { return }
        startForegroundSchedule()
        syncEngine.syncIncremental()
    }

    deinit {
        lifecycleObservation?.cancel()
        stopForegroundSchedule()
    }
}
