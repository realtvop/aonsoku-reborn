import Foundation

#if os(iOS)
import BackgroundTasks
#endif

/// One run of the background refresh handed out by the platform scheduler.
protocol BackgroundRefreshTask: AnyObject {
    /// Called when the platform wants the work to stop early. Only iOS
    /// delivers this; `NSBackgroundActivityScheduler` has no expiration.
    var expirationHandler: (() -> Void)? { get set }
    /// Reports that the run is over. Must be called exactly once.
    func setCompleted(success: Bool)
}

/// Best-effort periodic work while the app is not in use: `BGAppRefreshTask`
/// on iOS, `NSBackgroundActivityScheduler` on macOS.
protocol BackgroundRefreshScheduling: AnyObject, Sendable {
    /// Installs the handler that runs when a requested refresh fires. iOS
    /// requires this before the app finishes launching.
    func register(handler: @escaping @Sendable (BackgroundRefreshTask) -> Void)

    /// Asks for one run no earlier than `interval` seconds from now, replacing
    /// any request that has not started yet.
    func schedule(after interval: TimeInterval)
}

enum PlatformBackgroundRefresh {
    static func makeScheduler(identifier: String) -> BackgroundRefreshScheduling {
        #if os(iOS)
        BGTaskRefreshScheduler(identifier: identifier)
        #else
        ActivityRefreshScheduler(identifier: identifier)
        #endif
    }
}

#if os(iOS)

final class BGTaskRefreshScheduler: BackgroundRefreshScheduling, @unchecked Sendable {
    private let identifier: String

    init(identifier: String) {
        self.identifier = identifier
    }

    func register(handler: @escaping @Sendable (BackgroundRefreshTask) -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handler(BGRefreshTaskAdapter(refreshTask))
        }
    }

    func schedule(after interval: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }
}

private final class BGRefreshTaskAdapter: BackgroundRefreshTask {
    private let task: BGAppRefreshTask

    init(_ task: BGAppRefreshTask) {
        self.task = task
    }

    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    func setCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

#elseif os(macOS)

/// Runs the refresh through `NSBackgroundActivityScheduler`, which lets the
/// system pick a power-friendly moment within the tolerance window.
final class ActivityRefreshScheduler: BackgroundRefreshScheduling, @unchecked Sendable {
    private let identifier: String
    private let lock = NSLock()
    private var handler: (@Sendable (BackgroundRefreshTask) -> Void)?
    private var pending: NSBackgroundActivityScheduler?

    init(identifier: String) {
        self.identifier = identifier
    }

    func register(handler: @escaping @Sendable (BackgroundRefreshTask) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func schedule(after interval: TimeInterval) {
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = false
        scheduler.interval = max(1, interval)
        scheduler.tolerance = max(1, interval) / 2
        scheduler.qualityOfService = .utility
        let replaced = lock.withLock { () -> NSBackgroundActivityScheduler? in
            let old = pending
            pending = scheduler
            return old
        }
        // Only a request that has not started is replaced: the handler asks
        // for its successor while it is still running, and that run must not
        // be invalidated underneath it.
        replaced?.invalidate()
        scheduler.schedule { [weak self, weak scheduler] completion in
            guard let self, let scheduler else {
                completion(.finished)
                return
            }
            let handler = self.lock.withLock { () -> (@Sendable (BackgroundRefreshTask) -> Void)? in
                if self.pending === scheduler { self.pending = nil }
                return self.handler
            }
            guard let handler else {
                completion(.finished)
                return
            }
            handler(ActivityRefreshTask(scheduler: scheduler, completion: completion))
        }
    }
}

private final class ActivityRefreshTask: BackgroundRefreshTask, @unchecked Sendable {
    var expirationHandler: (() -> Void)?
    // Keeps the scheduler alive until the run reports completion.
    private var scheduler: NSBackgroundActivityScheduler?
    private var completion: NSBackgroundActivityScheduler.CompletionHandler?
    private let lock = NSLock()

    init(
        scheduler: NSBackgroundActivityScheduler,
        completion: @escaping NSBackgroundActivityScheduler.CompletionHandler
    ) {
        self.scheduler = scheduler
        self.completion = completion
    }

    func setCompleted(success: Bool) {
        let completion = lock.withLock { () -> NSBackgroundActivityScheduler.CompletionHandler? in
            let value = self.completion
            self.completion = nil
            self.scheduler = nil
            return value
        }
        // Always `.finished`: a deferred activity would run again at once,
        // while the handler has already requested its own successor.
        completion?(.finished)
    }
}

#endif
