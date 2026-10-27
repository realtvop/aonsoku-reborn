import Foundation

protocol NativeDownloadManagerDelegate: AnyObject {
    func downloadManager(_ manager: NativeDownloadManager, didProgress songId: String, requestId: String?, loaded: Int64, total: Int64)
    func downloadManager(_ manager: NativeDownloadManager, didComplete songId: String, requestId: String?, fileUrl: URL, contentType: String, sizeBytes: Int64)
    func downloadManager(_ manager: NativeDownloadManager, didFail songId: String, requestId: String?, error: Error)
}

enum DownloadError: Error {
    case noCredentials
    case invalidURL
    case httpError(Int)
    case fileMoveFailed
    case invalidAudioFile
}

class NativeDownloadManager: NSObject, URLSessionDownloadDelegate {
    static let backgroundSessionIdentifier = "github.realtvop.aonsoku.audio.downloads"
    static let downloadQueueStorageKey = "audio.downloadQueue.v1"
    typealias SessionFactory = (URLSessionDownloadDelegate) -> URLSession
    typealias ForegroundSessionFactory = (URL, URLSessionDownloadDelegate) async throws -> URLSession

    weak var delegate: NativeDownloadManagerDelegate?

    private var activeTasks: [Int: DownloadTaskContext] = [:]
    /// Unstarted tasks are not returned by URLSession.getAllTasks. Persist their
    /// request descriptors separately, without authenticated URLs/credentials.
    private var queuedTasks: [URLSessionTask] = []
    private var queuedRequests: [Int: DownloadRequest] = [:]
    private var requestsToRestore: [DownloadRequest]
    private var runningTaskIds: Set<Int> = []
    private var sessionTasks: [Int: URLSessionTask] = [:]
    private var finishedTaskIds: Set<Int> = []
    private var isRestoringTasks = false
    /// Task identifiers cancelled by the user. URLSession may still deliver
    /// delegate callbacks after `cancel()` wins a race with completion; those
    /// callbacks must not publish a completed download.
    private var cancelledTaskIds: Set<Int> = []
    /// New requests wait outside the URLSession while `cancelAll()` takes its
    /// task snapshot, so the snapshot cannot accidentally include them.
    private var isCancellingAll = false
    /// Requests that began before a cancel-all operation must not create a
    /// task after that operation has already taken its URLSession snapshot.
    private var cancelAllGeneration: UInt64 = 0
    /// Cancels requests that are still resolving credentials or moving out of
    /// the cancel-all deferred queue, before they own a URLSession task.
    private var songCancellationGenerations: [String: UInt64] = [:]
    private var deferredDownloads: [DownloadRequest] = []
    private var backgroundCompletionHandler: (() -> Void)?
    private let lock = NSLock()
    private let sessionFactory: SessionFactory
    private let foregroundSessionFactory: ForegroundSessionFactory
    private let routesThroughTailscale: (URL) -> Bool
    private var preparingRequests: [UUID: DownloadRequest] = [:]
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var foregroundSessions: [Int: URLSession] = [:]
    private var foregroundRequests: [Int: DownloadRequest] = [:]
    private let taskIdentityLock = NSLock()
    private struct TaskIdentity {
        weak var task: URLSessionTask?
        let key: Int
    }
    private var taskIdentities: [ObjectIdentifier: TaskIdentity] = [:]
    private var nextTaskIdentity = 0
    private let credentialsProvider: () -> ServerCredentials?
    private let estimateContentLengthProvider: () -> Bool
    private let cacheDirectoryProvider: (Bool) throws -> URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let preferences: PreferencesService
    private var preferencesObservation: PreferencesObservation?
    private let sessionLock = NSLock()
    private var storedSession: URLSession?

    private var session: URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let storedSession { return storedSession }
        lock.lock()
        isRestoringTasks = true
        lock.unlock()
        let created = sessionFactory(self)
        storedSession = created
        created.getAllTasks { [weak self] tasks in
            self?.restoreTasks(tasks)
        }
        return created
    }

    override convenience init() {
        self.init(sessionFactory: { delegate in
            Self.makeBackgroundSession(delegate: delegate)
        })
    }

    init(
        sessionFactory: @escaping SessionFactory,
        credentialsProvider: @escaping () -> ServerCredentials? = {
            KeychainManager.retrieve()
        },
        estimateContentLengthProvider: @escaping () -> Bool = {
            PreferencesService.shared.estimateStreamContentLength
        },
        preferences: PreferencesService = .shared,
        cacheDirectoryProvider: @escaping (Bool) throws -> URL = {
            try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: $0)
        },
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        routesThroughTailscale: @escaping (URL) -> Bool = { TailscaleRouting.shared.shouldRoute($0) },
        foregroundSessionFactory: @escaping ForegroundSessionFactory = { url, delegate in
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForResource = 600
            configuration.waitsForConnectivity = true
            return try await NetworkService.streamingSession(for: url, delegate: delegate, configuration: configuration)
        }
    ) {
        self.sessionFactory = sessionFactory
        self.foregroundSessionFactory = foregroundSessionFactory
        self.routesThroughTailscale = routesThroughTailscale
        self.credentialsProvider = credentialsProvider
        self.estimateContentLengthProvider = estimateContentLengthProvider
        self.cacheDirectoryProvider = cacheDirectoryProvider
        self.fileManager = fileManager
        self.now = now
        self.preferences = preferences
        requestsToRestore = preferences.getJSON(
            Self.downloadQueueStorageKey, as: [DownloadRequest].self
        ) ?? []
        var restoredContexts: Set<DownloadTaskContext> = []
        requestsToRestore = requestsToRestore.filter { restoredContexts.insert($0.context).inserted }
        for index in requestsToRestore.indices {
            requestsToRestore[index].songCancellationGeneration = 0
        }
        super.init()
        preferencesObservation = preferences.observe { [weak self] change in
            if change.key == SettingsStore.storageKey {
                self?.scheduleDownloads()
            }
        }
    }

    deinit { preferencesObservation?.cancel() }

    private static func makeBackgroundSession(
        delegate: URLSessionDownloadDelegate
    ) -> URLSession {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func download(
        songId: String,
        requestId: String? = nil,
        maxBitRate: Int? = nil,
        format: String? = nil
    ) {
        lock.lock()
        let request = DownloadRequest(
            context: DownloadTaskContext(songId: songId, requestId: requestId),
            maxBitRate: maxBitRate,
            format: format,
            songCancellationGeneration: songCancellationGenerations[songId, default: 0]
        )
        if isCancellingAll {
            deferredDownloads.append(request)
            lock.unlock()
            return
        }
        let generation = cancelAllGeneration
        lock.unlock()
        start(request, generation: generation)
    }

    private func start(_ request: DownloadRequest, generation: UInt64) {
        let context = request.context
        guard let credentials = credentialsProvider() else {
            guard isCurrent(request, generation: generation) else { return }
            delegate?.downloadManager(
                self,
                didFail: context.songId,
                requestId: context.requestId,
                error: DownloadError.noCredentials
            )
            return
        }
        guard let url = buildDownloadURL(
            songId: context.songId,
            credentials: credentials,
            maxBitRate: request.maxBitRate,
            format: request.format
        ) else {
            guard isCurrent(request, generation: generation) else { return }
            delegate?.downloadManager(
                self,
                didFail: context.songId,
                requestId: context.requestId,
                error: DownloadError.invalidURL
            )
            return
        }

        let routing = TailscaleRouting.shared.current
        if routesThroughTailscale(url) || (routing.enabled && routing.acceptSubnetRoutes) {
            prepareForegroundDownload(request, url: url, generation: generation)
        } else {
            enqueue(request, url: url, in: session, foreground: false, generation: generation)
        }
    }

    private func prepareForegroundDownload(_ request: DownloadRequest, url: URL, generation: UInt64) {
        let preparationID = UUID()
        lock.lock()
        guard isCurrentLocked(request, generation: generation) else { lock.unlock(); return }
        preparingRequests[preparationID] = request
        persistQueueLocked()
        lock.unlock()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock {
                    self.preparingRequests.removeValue(forKey: preparationID)
                    self.preparations.removeValue(forKey: preparationID)
                    self.persistQueueLocked()
                }
            }
            do {
                await NetworkService.prepareTailscaleRouting()
                try Task.checkCancellation()
                if !self.routesThroughTailscale(url) {
                    self.enqueue(request, url: url, in: self.session, foreground: false, generation: generation)
                    return
                }
                let session = try await self.foregroundSessionFactory(url, self)
                if Task.isCancelled { session.invalidateAndCancel(); return }
                self.enqueue(request, url: url, in: session, foreground: true, generation: generation)
            } catch {
                guard !Task.isCancelled, self.isCurrent(request, generation: generation) else { return }
                self.delegate?.downloadManager(self, didFail: request.context.songId,
                                               requestId: request.context.requestId, error: error)
            }
        }
        lock.withLock {
            if preparingRequests[preparationID] != nil { preparations[preparationID] = task } else { task.cancel() }
        }
    }

    private func enqueue(_ request: DownloadRequest, url: URL, in activeSession: URLSession,
                         foreground: Bool, generation: UInt64) {
        let context = request.context
        lock.lock()
        guard isCurrentLocked(request, generation: generation) else {
            lock.unlock()
            if foreground { activeSession.invalidateAndCancel() }
            return
        }
        let task = activeSession.downloadTask(with: url)
        task.taskDescription = Self.encode(context)
        activeTasks[taskKey(task)] = context
        sessionTasks[taskKey(task)] = task
        queuedTasks.append(task)
        queuedRequests[taskKey(task)] = request
        if foreground {
            foregroundSessions[taskKey(task)] = activeSession
            foregroundRequests[taskKey(task)] = request
        }
        persistQueueLocked()
        lock.unlock()
        scheduleDownloads()
    }

    func cancel(songId: String) {
        lock.lock()
        songCancellationGenerations[songId, default: 0] &+= 1
        let preparingIDs = preparingRequests.compactMap { $0.value.context.songId == songId ? $0.key : nil }
        for id in preparingIDs {
            preparingRequests.removeValue(forKey: id)
            preparations.removeValue(forKey: id)?.cancel()
        }
        let taskIds = Set(activeTasks.compactMap { taskId, context in
            context.songId == songId ? taskId : nil
        })
        for taskId in taskIds {
            activeTasks.removeValue(forKey: taskId)
            sessionTasks.removeValue(forKey: taskId)?.cancel()
            runningTaskIds.remove(taskId)
            queuedRequests.removeValue(forKey: taskId)
            foregroundRequests.removeValue(forKey: taskId)
            foregroundSessions.removeValue(forKey: taskId)?.invalidateAndCancel()
        }
        queuedTasks.removeAll { taskIds.contains(taskKey($0)) }
        requestsToRestore.removeAll { $0.context.songId == songId }
        persistQueueLocked()
        cancelledTaskIds.formUnion(taskIds)
        deferredDownloads.removeAll { $0.context.songId == songId }
        lock.unlock()

        scheduleDownloads()
    }

    func cancelAll() {
        lock.lock()
        if isCancellingAll {
            deferredDownloads.removeAll()
            lock.unlock()
            return
        }
        isCancellingAll = true
        cancelAllGeneration &+= 1
        for task in preparations.values { task.cancel() }
        preparations.removeAll()
        preparingRequests.removeAll()
        for session in foregroundSessions.values { session.invalidateAndCancel() }
        foregroundSessions.removeAll()
        foregroundRequests.removeAll()
        cancelledTaskIds.formUnion(activeTasks.keys)
        activeTasks.removeAll()
        queuedTasks.removeAll()
        queuedRequests.removeAll()
        requestsToRestore.removeAll()
        persistQueueLocked()
        runningTaskIds.removeAll()
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        lock.unlock()
        session.getAllTasks { tasks in
            self.lock.lock()
            self.cancelledTaskIds.formUnion(tasks.map { self.taskKey($0) })
            let deferred = self.deferredDownloads
            self.deferredDownloads.removeAll()
            self.isCancellingAll = false
            let generation = self.cancelAllGeneration
            self.lock.unlock()
            for task in tasks { task.cancel() }
            for request in deferred {
                self.start(request, generation: generation)
            }
            self.scheduleDownloads()
        }
    }

    private func restoreTasks(_ tasks: [URLSessionTask]) {
        lock.lock()
        var restoredTaskKeys = Set<Int>()
        for task in tasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
            let id = taskKey(task)
            guard !cancelledTaskIds.contains(id), !finishedTaskIds.contains(id),
                  sessionTasks[id] == nil,
                  task.state == .running || task.state == .suspended,
                  let context = Self.decode(task.taskDescription) else { continue }
            // A cancellation may precede this asynchronous session snapshot.
            // Newly created requests are already registered above and skipped.
            guard !isCancellingAll,
                  songCancellationGenerations[context.songId, default: 0] == 0 else {
                cancelledTaskIds.insert(id)
                task.cancel()
                continue
            }
            activeTasks[id] = context
            restoredTaskKeys.insert(id)
            sessionTasks[id] = task
            if task.state == .running {
                runningTaskIds.insert(id)
            } else {
                queuedTasks.append(task)
            }
        }
        queuedTasks.sort {
            let lhs = taskKey($0), rhs = taskKey($1)
            if restoredTaskKeys.contains(lhs) != restoredTaskKeys.contains(rhs) {
                return restoredTaskKeys.contains(lhs)
            }
            return lhs < rhs
        }
        let restored = requestsToRestore.filter { request in
            !activeTasks.values.contains { context in
                context.songId == request.context.songId
                    && context.requestId == request.context.requestId
            }
        }
        let generation = cancelAllGeneration
        lock.unlock()
        for request in restored {
            start(request, generation: generation)
        }
        lock.lock()
        // Recovered requests take precedence over new requests queued during
        // the session snapshot, preserving the user's original download order.
        let restoredIds = Set(restored.map { $0.context })
        queuedTasks = queuedTasks.filter { task in
            queuedRequests[taskKey(task)].map { restoredIds.contains($0.context) } ?? false
        } + queuedTasks.filter { task in
            !(queuedRequests[taskKey(task)].map { restoredIds.contains($0.context) } ?? false)
        }
        requestsToRestore.removeAll()
        persistQueueLocked()
        isRestoringTasks = false
        lock.unlock()
        scheduleDownloads()
    }

    /// Read the current setting on every fill. Lowering the limit lets existing
    /// transfers finish; raising it immediately admits more queued tracks.
    private func scheduleDownloads() {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancellingAll, !isRestoringTasks else { return }
        let limit = preferences.audioDownloadConcurrency
        while runningTaskIds.count < limit, !queuedTasks.isEmpty {
            let task = queuedTasks.removeFirst()
            queuedRequests.removeValue(forKey: taskKey(task))
            runningTaskIds.insert(taskKey(task))
            task.resume()
        }
        persistQueueLocked()
    }

    private func persistQueueLocked() {
        let waiting = requestsToRestore + queuedTasks.compactMap { queuedRequests[taskKey($0)] }
            + Array(preparingRequests.values) + foregroundRequests.sorted { $0.key < $1.key }.map(\.value)
        var seen = Set<DownloadTaskContext>()
        let unique = waiting.filter { seen.insert($0.context).inserted }
        try? preferences.setJSON(unique, for: Self.downloadQueueStorageKey)
    }

    /// Reconnect at normal launch too, even if no new download is requested.
    func restoreDownloads() {
        lock.lock()
        let hasWaitingRequests = !requestsToRestore.isEmpty
        lock.unlock()
        if hasWaitingRequests { _ = session }
    }

    var downloadTasksSnapshot: [URLSessionTask] {
        lock.lock()
        defer { lock.unlock() }
        return sessionTasks.values.sorted { taskKey($0) < taskKey($1) }
    }

    var activeDownloadSongIds: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(activeTasks.values.map(\.songId) + preparingRequests.values.map { $0.context.songId })
    }

    var isCancellingDownloads: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancellingAll
    }

    func handleEvents(
        forBackgroundSession identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == Self.backgroundSessionIdentifier else { return false }
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        _ = session
        return true
    }

    func buildDownloadURL(
        songId: String,
        credentials: ServerCredentials,
        maxBitRate: Int?,
        format: String?
    ) -> URL? {
        var params = SubsonicAuthBuilder.buildQueryParams(
            username: credentials.username,
            password: credentials.password,
            authType: credentials.authType,
            protocolVersion: credentials.protocolVersion
        )
        params["id"] = songId
        params["estimateContentLength"] = String(estimateContentLengthProvider())
        if let maxBitRate { params["maxBitRate"] = String(maxBitRate) }
        if let format { params["format"] = format }

        let cleanBaseUrl = credentials.serverUrl.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard var components = URLComponents(
            string: "\(cleanBaseUrl)/rest/stream"
        ) else {
            return nil
        }
        components.queryItems = params.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.url
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let context = context(for: downloadTask) else {
            return
        }

        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        delegate?.downloadManager(
            self,
            didProgress: context.songId,
            requestId: context.requestId,
            loaded: totalBytesWritten,
            total: total
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        defer { scheduleDownloads() }
        guard let context = removeContext(for: downloadTask) else {
            return
        }
        let songId = context.songId

        let httpResponse = downloadTask.response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 200

        guard statusCode >= 200, statusCode < 300 else {
            delegate?.downloadManager(
                self,
                didFail: songId,
                requestId: context.requestId,
                error: DownloadError.httpError(statusCode)
            )
            return
        }

        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"
        let normalizedType = contentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let attributes = try? fileManager.attributesOfItem(atPath: location.path)
        let downloadedSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard downloadedSize > 0,
              !normalizedType.hasPrefix("text/"),
              !["application/json", "application/xml", "application/xhtml+xml"].contains(normalizedType) else {
            delegate?.downloadManager(
                self, didFail: songId, requestId: context.requestId,
                error: DownloadError.invalidAudioFile
            )
            return
        }
        let ext = AudioCacheUtils.fileExtension(for: contentType)
        let cacheId = AudioCacheUtils.cacheId(for: songId)

        do {
            let directory = try cacheDirectoryProvider(true)
            let destURL = directory.appendingPathComponent("\(cacheId).\(ext)", isDirectory: false)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: location, to: destURL)

            let attrs = try? fileManager.attributesOfItem(atPath: destURL.path)
            let sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

            let metadata = NativeCachedAudioFileMetadata(
                songId: songId,
                fileName: "\(cacheId).\(ext)",
                contentType: contentType,
                lastModifiedAt: now().timeIntervalSince1970 * 1000
            )
            let metadataData = try JSONEncoder().encode(metadata)
            let metadataURL = directory.appendingPathComponent("\(cacheId).json", isDirectory: false)
            try metadataData.write(to: metadataURL, options: [.atomic])

            delegate?.downloadManager(
                self,
                didComplete: songId,
                requestId: context.requestId,
                fileUrl: destURL,
                contentType: contentType,
                sizeBytes: sizeBytes
            )
        } catch {
            delegate?.downloadManager(
                self,
                didFail: songId,
                requestId: context.requestId,
                error: DownloadError.fileMoveFailed
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { scheduleDownloads() }
        guard let context = removeContext(for: task) else {
            return
        }

        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        delegate?.downloadManager(
            self,
            didFail: context.songId,
            requestId: context.requestId,
            error: error
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { completionHandler?() }
    }

    private func context(for task: URLSessionTask) -> DownloadTaskContext? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelledTaskIds.contains(taskKey(task)) else { return nil }
        guard !finishedTaskIds.contains(taskKey(task)) else { return nil }
        if let context = activeTasks[taskKey(task)] { return context }
        guard let context = Self.decode(task.taskDescription) else { return nil }
        activeTasks[taskKey(task)] = context
        sessionTasks[taskKey(task)] = task
        runningTaskIds.insert(taskKey(task))
        return context
    }

    private func removeContext(for task: URLSessionTask) -> DownloadTaskContext? {
        lock.lock()
        defer { lock.unlock() }
        let id = taskKey(task)
        guard finishedTaskIds.insert(id).inserted else { return nil }
        sessionTasks.removeValue(forKey: id)
        foregroundRequests.removeValue(forKey: id)
        foregroundSessions.removeValue(forKey: id)?.finishTasksAndInvalidate()
        queuedRequests.removeValue(forKey: id)
        runningTaskIds.remove(id)
        queuedTasks.removeAll { taskKey($0) == id }
        if cancelledTaskIds.contains(id) {
            activeTasks.removeValue(forKey: taskKey(task))
            return nil
        }
        return activeTasks.removeValue(forKey: taskKey(task))
            ?? Self.decode(task.taskDescription)
    }

    private func isCurrent(
        _ request: DownloadRequest,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentLocked(request, generation: generation)
    }

    private func isCurrentLocked(_ request: DownloadRequest, generation: UInt64) -> Bool {
        !isCancellingAll
            && cancelAllGeneration == generation
            && songCancellationGenerations[request.context.songId, default: 0]
            == request.songCancellationGeneration
    }

    /// URLSession task identifiers are only unique within one session. Tailnet
    /// transfers use foreground sessions, so they need manager-wide identities.
    private func taskKey(_ task: URLSessionTask) -> Int {
        taskIdentityLock.withLock {
            let identity = ObjectIdentifier(task)
            if let entry = taskIdentities[identity], entry.task === task { return entry.key }
            nextTaskIdentity += 1
            taskIdentities[identity] = TaskIdentity(task: task, key: nextTaskIdentity)
            if taskIdentities.count > 128, taskIdentities.count.isMultiple(of: 64) {
                taskIdentities = taskIdentities.filter { $0.value.task != nil }
            }
            return nextTaskIdentity
        }
    }

    private static func encode(_ context: DownloadTaskContext) -> String {
        guard let data = try? JSONEncoder().encode(context),
              let value = String(data: data, encoding: .utf8) else {
            return context.songId
        }
        return value
    }

    private static func decode(_ value: String?) -> DownloadTaskContext? {
        guard let value, !value.isEmpty else { return nil }
        if let data = value.data(using: .utf8),
           let context = try? JSONDecoder().decode(DownloadTaskContext.self, from: data) {
            return context
        }
        // Compatibility with downloads created before request IDs were added.
        return DownloadTaskContext(songId: value, requestId: nil)
    }
}

private struct DownloadTaskContext: Codable, Hashable {
    var songId: String
    var requestId: String?
}

private struct DownloadRequest: Codable {
    var context: DownloadTaskContext
    var maxBitRate: Int?
    var format: String?
    var songCancellationGeneration: UInt64
}
