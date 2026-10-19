import Foundation
import UIKit
import BackgroundTasks

public final class SyncScheduler {
    public static let bgTaskIdentifier = "github.realtvop.aonsoku.sync.refresh"

    private static var shared: SyncScheduler?

    private let syncEngine: SyncEngine
    private var foregroundTimer: Timer?
    private var isInForeground = true

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
        Self.shared = self
        observeAppLifecycle()
    }

    func startForegroundSchedule() {
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
            if let shared = Self.shared {
                shared.handleBackgroundRefresh(task as! BGAppRefreshTask)
            } else {
                let db = DatabaseManager.shared.dbPool
                let httpClient = SubsonicHTTPClient()
                let syncEngine = SyncEngine(db: db, httpClient: httpClient)

                // Schedule next background refresh
                let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
                request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
                try? BGTaskScheduler.shared.submit(request)

                let syncTask = Task {
                    syncEngine.syncAll(includeFullSongs: false, mode: "incremental")
                }

                task.expirationHandler = {
                    syncEngine.cancel()
                    syncTask.cancel()
                }

                Task {
                    _ = await syncTask.value
                    task.setTaskCompleted(success: true)
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
            syncEngine.syncAll(includeFullSongs: false, mode: "incremental")
        }

        task.expirationHandler = { [weak self] in
            self?.syncEngine.cancel()
            syncTask.cancel()
        }

        Task {
            _ = await syncTask.value
            task.setTaskCompleted(success: true)
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
        startForegroundSchedule()
        syncEngine.syncIncremental()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopForegroundSchedule()
    }
}
