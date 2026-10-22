import Foundation
import UIKit
import BackgroundTasks

public final class SyncScheduler {
    public static let bgTaskIdentifier = "github.realtvop.aonsoku.sync.refresh"

    private static var shared: SyncScheduler?

    private let syncEngine: SyncEngine
    private var foregroundTimer: Timer?
    private var isInForeground = true
    private(set) var isForegroundSchedulingEnabled = false

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
        Self.shared = self
        observeAppLifecycle()
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

    // MARK: - Background Tasks

    public static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            if let shared = Self.shared {
                shared.handleBackgroundRefresh(refreshTask)
            } else {
                let db = DatabaseManager.shared.dbPool
                let httpClient = SubsonicHTTPClient()
                let syncEngine = SyncEngine(db: db, httpClient: httpClient)

                // Schedule next background refresh
                let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
                request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
                try? BGTaskScheduler.shared.submit(request)

                let syncTask = Task {
                    await syncEngine.syncAllAndWait(
                        includeFullSongs: false,
                        mode: "incremental"
                    )
                }

                refreshTask.expirationHandler = {
                    syncEngine.cancel()
                    syncTask.cancel()
                }

                Task {
                    let succeeded = await syncTask.value
                    refreshTask.setTaskCompleted(success: succeeded)
                }
            }
        }
    }

    func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
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
            task.setTaskCompleted(success: succeeded)
        }
    }

    // MARK: - App Lifecycle

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        isInForeground = false
        stopForegroundSchedule()
        scheduleNextBackgroundRefresh()
    }

    @objc private func appWillEnterForeground() {
        isInForeground = true
        guard isForegroundSchedulingEnabled else { return }
        startForegroundSchedule()
        syncEngine.syncIncremental()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopForegroundSchedule()
    }
}
