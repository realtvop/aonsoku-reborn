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
    typealias SessionFactory = (URLSessionDownloadDelegate) -> URLSession

    weak var delegate: NativeDownloadManagerDelegate?

    private var activeTasks: [Int: DownloadTaskContext] = [:]
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
    private let credentialsProvider: () -> ServerCredentials?
    private let estimateContentLengthProvider: () -> Bool
    private let cacheDirectoryProvider: (Bool) throws -> URL
    private let fileManager: FileManager
    private let now: () -> Date

    private lazy var session: URLSession = {
        sessionFactory(self)
    }()

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
        cacheDirectoryProvider: @escaping (Bool) throws -> URL = {
            try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: $0)
        },
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionFactory = sessionFactory
        self.credentialsProvider = credentialsProvider
        self.estimateContentLengthProvider = estimateContentLengthProvider
        self.cacheDirectoryProvider = cacheDirectoryProvider
        self.fileManager = fileManager
        self.now = now
        super.init()
    }

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

        let activeSession = session
        lock.lock()
        guard !isCancellingAll,
              cancelAllGeneration == generation,
              songCancellationGenerations[context.songId, default: 0]
              == request.songCancellationGeneration else {
            lock.unlock()
            return
        }
        let task = activeSession.downloadTask(with: url)
        task.taskDescription = Self.encode(context)
        activeTasks[task.taskIdentifier] = context
        lock.unlock()
        task.resume()
    }

    func cancel(songId: String) {
        lock.lock()
        songCancellationGenerations[songId, default: 0] &+= 1
        let taskIds = Set(activeTasks.compactMap { taskId, context in
            context.songId == songId ? taskId : nil
        })
        for taskId in taskIds {
            activeTasks.removeValue(forKey: taskId)
        }
        cancelledTaskIds.formUnion(taskIds)
        deferredDownloads.removeAll { $0.context.songId == songId }
        lock.unlock()

        guard !taskIds.isEmpty else { return }
        session.getAllTasks { tasks in
            for task in tasks where taskIds.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
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
        cancelledTaskIds.formUnion(activeTasks.keys)
        activeTasks.removeAll()
        lock.unlock()
        session.getAllTasks { tasks in
            self.lock.lock()
            self.cancelledTaskIds.formUnion(tasks.map(\.taskIdentifier))
            let deferred = self.deferredDownloads
            self.deferredDownloads.removeAll()
            self.isCancellingAll = false
            let generation = self.cancelAllGeneration
            self.lock.unlock()
            for task in tasks { task.cancel() }
            for request in deferred {
                self.start(request, generation: generation)
            }
        }
    }

    var activeDownloadSongIds: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(activeTasks.values.map(\.songId))
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
        guard let error else { return }

        guard let context = removeContext(for: task) else {
            return
        }

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
        guard !cancelledTaskIds.contains(task.taskIdentifier) else { return nil }
        if let context = activeTasks[task.taskIdentifier] { return context }
        guard let context = Self.decode(task.taskDescription) else { return nil }
        activeTasks[task.taskIdentifier] = context
        return context
    }

    private func removeContext(for task: URLSessionTask) -> DownloadTaskContext? {
        lock.lock()
        defer { lock.unlock() }
        if cancelledTaskIds.remove(task.taskIdentifier) != nil {
            activeTasks.removeValue(forKey: task.taskIdentifier)
            return nil
        }
        return activeTasks.removeValue(forKey: task.taskIdentifier)
            ?? Self.decode(task.taskDescription)
    }

    private func isCurrent(
        _ request: DownloadRequest,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isCancellingAll
            && cancelAllGeneration == generation
            && songCancellationGenerations[request.context.songId, default: 0]
            == request.songCancellationGeneration
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

private struct DownloadTaskContext: Codable {
    var songId: String
    var requestId: String?
}

private struct DownloadRequest {
    var context: DownloadTaskContext
    var maxBitRate: Int?
    var format: String?
    var songCancellationGeneration: UInt64
}
