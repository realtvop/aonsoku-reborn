import Foundation

protocol NativeDownloadManagerDelegate: AnyObject {
    func downloadManager(_ manager: NativeDownloadManager, didProgress songId: String, loaded: Int64, total: Int64)
    func downloadManager(_ manager: NativeDownloadManager, didComplete songId: String, fileUrl: URL, contentType: String, sizeBytes: Int64)
    func downloadManager(_ manager: NativeDownloadManager, didFail songId: String, error: Error)
}

enum DownloadError: Error {
    case noCredentials
    case invalidURL
    case httpError(Int)
    case fileMoveFailed
}

class NativeDownloadManager: NSObject, URLSessionDownloadDelegate {
    static let backgroundSessionIdentifier = "github.realtvop.aonsoku.audio.downloads"
    typealias SessionFactory = (URLSessionDownloadDelegate) -> URLSession

    weak var delegate: NativeDownloadManagerDelegate?

    private var activeTasks: [Int: String] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private let lock = NSLock()
    private let sessionFactory: SessionFactory
    private let credentialsProvider: () -> ServerCredentials?
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
        cacheDirectoryProvider: @escaping (Bool) throws -> URL = {
            try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: $0)
        },
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionFactory = sessionFactory
        self.credentialsProvider = credentialsProvider
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

    func download(songId: String, maxBitRate: Int? = nil, format: String? = nil) {
        guard let credentials = credentialsProvider() else {
            delegate?.downloadManager(self, didFail: songId, error: DownloadError.noCredentials)
            return
        }
        guard let url = buildDownloadURL(
            songId: songId,
            credentials: credentials,
            maxBitRate: maxBitRate,
            format: format
        ) else {
            delegate?.downloadManager(self, didFail: songId, error: DownloadError.invalidURL)
            return
        }

        let task = session.downloadTask(with: url)
        task.taskDescription = songId
        lock.lock()
        activeTasks[task.taskIdentifier] = songId
        lock.unlock()
        task.resume()
    }

    func cancel(songId: String) {
        lock.lock()
        let taskId = activeTasks.first(where: { $0.value == songId })?.key
        if let taskId { activeTasks.removeValue(forKey: taskId) }
        lock.unlock()

        guard let taskId else { return }
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
        lock.lock()
        activeTasks.removeAll()
        lock.unlock()
    }

    var activeDownloadSongIds: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(activeTasks.values)
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
        params["estimateContentLength"] = "true"
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
        guard let songId = songId(for: downloadTask) else {
            return
        }

        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        delegate?.downloadManager(self, didProgress: songId, loaded: totalBytesWritten, total: total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let songId = removeSongId(for: downloadTask) else {
            return
        }

        let httpResponse = downloadTask.response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 200

        guard statusCode >= 200, statusCode < 300 else {
            delegate?.downloadManager(self, didFail: songId, error: DownloadError.httpError(statusCode))
            return
        }

        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"
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

            delegate?.downloadManager(self, didComplete: songId, fileUrl: destURL, contentType: contentType, sizeBytes: sizeBytes)
        } catch {
            delegate?.downloadManager(self, didFail: songId, error: DownloadError.fileMoveFailed)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        guard let songId = removeSongId(for: task) else {
            return
        }

        if (error as NSError).code == NSURLErrorCancelled { return }
        delegate?.downloadManager(self, didFail: songId, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { completionHandler?() }
    }

    private func songId(for task: URLSessionTask) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let songId = activeTasks[task.taskIdentifier] { return songId }
        guard let songId = task.taskDescription, !songId.isEmpty else { return nil }
        activeTasks[task.taskIdentifier] = songId
        return songId
    }

    private func removeSongId(for task: URLSessionTask) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks.removeValue(forKey: task.taskIdentifier)
            ?? task.taskDescription
    }
}
