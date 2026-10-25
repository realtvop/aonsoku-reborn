import AVFoundation
import Foundation

protocol StreamingResourceLoaderDelegate: AnyObject {
    func resourceLoader(_ loader: StreamingResourceLoader, didCompleteCache fileURL: URL, contentType: String, sizeBytes: Int64)
    func resourceLoader(_ loader: StreamingResourceLoader, didFailWithError error: Error)
}

final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "aonsoku-loader"

    let songId: String
    let originalURL: URL
    weak var delegate: StreamingResourceLoaderDelegate?

    private let queue = DispatchQueue(label: "com.aonsoku.StreamingResourceLoader", qos: .userInitiated)
    private var session: URLSession!
    private var pendingRequests: [Int: RequestState] = [:]
    private var rangeTracker = ByteRangeTracker()
    private var totalContentLength: Int64 = -1
    private var contentType: String?
    private var tempFileURL: URL?
    private var tempFileHandle: FileHandle?
    private var isCancelled = false
    private var cacheCompleted = false
    private var nextRequestId = 0

    init(songId: String, originalURL: URL) {
        self.songId = songId
        self.originalURL = originalURL
        super.init()
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        setupTempFile()
    }

    // MARK: - Public

    static func loaderURL(for originalURL: URL) -> URL? {
        guard let encoded = originalURL.absoluteString.data(using: .utf8)?
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "stream"
        components.path = "/\(encoded)"
        return components.url
    }

    static func originalURL(from loaderURL: URL) -> URL? {
        guard let components = URLComponents(url: loaderURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var encoded = String(components.path.dropFirst()) // remove leading "/"
        encoded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-add padding
        let remainder = encoded.count % 4
        if remainder > 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded),
              let urlString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return URL(string: urlString)
    }

    func cancel() {
        queue.async { [self] in
            isCancelled = true
            session.invalidateAndCancel()
            for (_, state) in pendingRequests {
                state.task?.cancel()
            }
            pendingRequests.removeAll()
            closeTempFile()
        }
    }

    func cleanupTempFile() {
        queue.async { [self] in
            closeTempFile()
            if let url = tempFileURL {
                try? FileManager.default.removeItem(at: url)
                tempFileURL = nil
            }
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        NativeLogger.shared.info("ResourceLoader: shouldWaitForLoading called, url=\(loadingRequest.request.url?.absoluteString.prefix(60) ?? "nil")", source: "Audio")
        queue.async { [self] in
            guard !isCancelled else {
                loadingRequest.finishLoading(with: URLError(.cancelled))
                return
            }
            handleLoadingRequest(loadingRequest)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        queue.async { [self] in
            if let entry = pendingRequests.first(where: { $0.value.loadingRequest === loadingRequest }) {
                entry.value.task?.cancel()
                pendingRequests.removeValue(forKey: entry.key)
            }
        }
    }

    // MARK: - Private

    private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let hasContentReq = loadingRequest.contentInformationRequest != nil
        let hasDataReq = loadingRequest.dataRequest != nil
        let offset = loadingRequest.dataRequest.map { Int64($0.requestedOffset) } ?? -1
        let length = loadingRequest.dataRequest.map { Int64($0.requestedLength) } ?? -1
        let toEnd = loadingRequest.dataRequest?.requestsAllDataToEndOfResource ?? false
        NativeLogger.shared.info("ResourceLoader: handleRequest contentInfo=\(hasContentReq) dataReq=\(hasDataReq) offset=\(offset) length=\(length) toEnd=\(toEnd)", source: "Audio")

        if let contentRequest = loadingRequest.contentInformationRequest {
            if totalContentLength > 0, let contentType {
                fillContentInfo(contentRequest, contentType: contentType, contentLength: totalContentLength)
                if loadingRequest.dataRequest == nil {
                    loadingRequest.finishLoading()
                    return
                }
            }
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            startDataTask(for: loadingRequest, offset: 0, requestsToEnd: true)
            return
        }

        let reqOffset = Int64(dataRequest.requestedOffset)
        let requestsToEnd = dataRequest.requestsAllDataToEndOfResource
        let reqLength: Int64? = requestsToEnd ? nil : Int64(dataRequest.requestedLength)
        startDataTask(for: loadingRequest, offset: reqOffset, requestsToEnd: requestsToEnd, length: reqLength)
    }

    private func startDataTask(for loadingRequest: AVAssetResourceLoadingRequest, offset: Int64, requestsToEnd: Bool, length: Int64? = nil) {
        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if offset > 0 && requestsToEnd {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else if offset > 0, let length {
            let end = offset + length - 1
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        }
        // offset == 0 with requestsToEnd: no Range header (full file request)

        let requestId = nextRequestId
        nextRequestId += 1

        let task = session.dataTask(with: request)
        let state = RequestState(
            loadingRequest: loadingRequest,
            task: task,
            currentOffset: offset,
            requestedOffset: offset
        )
        pendingRequests[requestId] = state
        task.resume()
    }

    private func setupTempFile() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "aonsoku_stream_\(songId)_\(UUID().uuidString).tmp"
        tempFileURL = tempDir.appendingPathComponent(fileName)

        guard let url = tempFileURL else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        tempFileHandle = try? FileHandle(forUpdating: url)
    }

    private func preallocateTempFile(length: Int64) {
        guard let handle = tempFileHandle else { return }
        do {
            try handle.seek(toOffset: UInt64(length - 1))
            handle.write(Data([0]))
            try handle.seek(toOffset: 0)
        } catch {
            closeTempFile()
        }
    }

    private func closeTempFile() {
        try? tempFileHandle?.close()
        tempFileHandle = nil
    }

    private func truncateTempFile(to length: Int64) {
        guard let handle = tempFileHandle else { return }
        do {
            try handle.truncate(atOffset: UInt64(length))
        } catch {
            NativeLogger.shared.warn("ResourceLoader: failed to truncate temp file: \(error.localizedDescription)", source: "Audio")
        }
    }

    private func fillContentInfo(_ request: AVAssetResourceLoadingContentInformationRequest, contentType: String, contentLength: Int64) {
        let uti = contentTypeToUTType(contentType)
        request.contentType = uti
        request.contentLength = contentLength
        request.isByteRangeAccessSupported = false
    }

    private func contentTypeToUTType(_ mimeType: String) -> String {
        let normalized = mimeType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch normalized {
        case "audio/mpeg", "audio/mp3":
            return "public.mp3"
        case "audio/flac", "audio/x-flac":
            return "org.xiph.flac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac":
            return "public.mpeg-4-audio"
        case "audio/ogg", "application/ogg", "audio/opus":
            return "org.xiph.ogg"
        case "audio/wav", "audio/x-wav":
            return "com.microsoft.waveform-audio"
        case "application/octet-stream", "":
            return inferUTTypeFromURL()
        default:
            return "public.audio"
        }
    }

    private func inferUTTypeFromURL() -> String {
        let ext = originalURL.pathExtension.lowercased()
        switch ext {
        case "mp3":
            return "public.mp3"
        case "flac":
            return "org.xiph.flac"
        case "m4a", "aac", "mp4":
            return "public.mpeg-4-audio"
        case "ogg", "opus":
            return "org.xiph.ogg"
        case "wav":
            return "com.microsoft.waveform-audio"
        default:
            return "public.mp3"
        }
    }

    private func checkCacheCompletion() {
        guard !cacheCompleted, totalContentLength > 0 else { return }
        guard rangeTracker.isComplete(totalLength: totalContentLength) else { return }

        cacheCompleted = true
        closeTempFile()

        guard let tempURL = tempFileURL, let contentType else { return }
        let actualSize = rangeTracker.totalBytesDownloaded
        delegate?.resourceLoader(self, didCompleteCache: tempURL, contentType: contentType, sizeBytes: actualSize)
    }
}

// MARK: - URLSessionDataDelegate

extension StreamingResourceLoader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async { [self] in
            guard let httpResponse = response as? HTTPURLResponse else {
                NativeLogger.shared.warn("ResourceLoader: non-HTTP response", source: "Audio")
                completionHandler(.cancel)
                return
            }

            let statusCode = httpResponse.statusCode
            NativeLogger.shared.info("ResourceLoader: HTTP \(statusCode), Content-Type=\(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil"), Content-Length=\(httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "nil")", source: "Audio")
            guard (200..<300).contains(statusCode) else {
                NativeLogger.shared.warn("StreamingResourceLoader: HTTP \(statusCode) for \(songId)", source: "Audio")
                completionHandler(.cancel)
                return
            }

            if contentType == nil {
                contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
            }

            if totalContentLength <= 0 {
                if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
                   let totalStr = contentRange.split(separator: "/").last,
                   totalStr != "*",
                   let total = Int64(totalStr) {
                    totalContentLength = total
                    preallocateTempFile(length: total)
                } else if let cl = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                          let length = Int64(cl), statusCode == 200 {
                    totalContentLength = length
                    preallocateTempFile(length: length)
                }
            }

            if let entry = pendingRequests.first(where: { $0.value.task?.taskIdentifier == dataTask.taskIdentifier }) {
                // If we requested a Range but got 200, server doesn't support Range.
                // Reset currentOffset to 0 since data starts from beginning.
                if statusCode == 200 && entry.value.requestedOffset > 0 {
                    entry.value.currentOffset = 0
                }

                if let contentInfo = entry.value.loadingRequest.contentInformationRequest {
                    if totalContentLength > 0, let contentType {
                        fillContentInfo(contentInfo, contentType: contentType, contentLength: totalContentLength)
                    } else if let contentType {
                        // Unknown length — still fill content type so AVPlayer can decode
                        contentInfo.contentType = contentTypeToUTType(contentType)
                        contentInfo.isByteRangeAccessSupported = false
                    }
                }
            }

            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [self] in
            guard let entry = pendingRequests.first(where: { $0.value.task?.taskIdentifier == dataTask.taskIdentifier }) else {
                return
            }

            let state = entry.value
            let offset = state.currentOffset
            let hasDataRequest = state.loadingRequest.dataRequest != nil

            if hasDataRequest {
                state.loadingRequest.dataRequest?.respond(with: data)
            }
            state.currentOffset += Int64(data.count)

            let range = offset..<(offset + Int64(data.count))
            rangeTracker.insert(range)

            if let handle = tempFileHandle {
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    handle.write(data)
                } catch {
                    closeTempFile()
                }
            }

            // If this request has received enough data, finish it immediately
            if let dataReq = state.loadingRequest.dataRequest,
               !dataReq.requestsAllDataToEndOfResource {
                let satisfied = state.currentOffset - Int64(dataReq.requestedOffset)
                if satisfied >= Int64(dataReq.requestedLength) {
                    state.loadingRequest.finishLoading()
                    state.task?.cancel()
                    pendingRequests.removeValue(forKey: entry.key)
                    return
                }
            }

            checkCacheCompletion()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [self] in
            guard let entry = pendingRequests.first(where: { $0.value.task?.taskIdentifier == task.taskIdentifier }) else {
                return
            }

            let requestId = entry.key
            let state = entry.value
            pendingRequests.removeValue(forKey: requestId)

            if let error {
                if (error as NSError).code != NSURLErrorCancelled {
                    NativeLogger.shared.warn("ResourceLoader: task failed: \(error.localizedDescription)", source: "Audio")
                    state.loadingRequest.finishLoading(with: error)
                    if pendingRequests.isEmpty && !cacheCompleted {
                        delegate?.resourceLoader(self, didFailWithError: error)
                    }
                }
            } else {
                let actualBytes = rangeTracker.totalBytesDownloaded
                NativeLogger.shared.info("ResourceLoader: task completed, totalBytes=\(actualBytes)", source: "Audio")
                state.loadingRequest.finishLoading()

                if state.requestedOffset == 0 && pendingRequests.isEmpty && actualBytes > 0 {
                    if totalContentLength != actualBytes {
                        NativeLogger.shared.info("ResourceLoader: correcting totalContentLength from \(totalContentLength) to \(actualBytes)", source: "Audio")
                        if totalContentLength > actualBytes {
                            truncateTempFile(to: actualBytes)
                        }
                        totalContentLength = actualBytes
                    }
                }

                checkCacheCompletion()
            }
        }
    }
}

// MARK: - RequestState

private final class RequestState {
    let loadingRequest: AVAssetResourceLoadingRequest
    let task: URLSessionDataTask?
    var currentOffset: Int64
    let requestedOffset: Int64

    init(loadingRequest: AVAssetResourceLoadingRequest, task: URLSessionDataTask?, currentOffset: Int64, requestedOffset: Int64) {
        self.loadingRequest = loadingRequest
        self.task = task
        self.currentOffset = currentOffset
        self.requestedOffset = requestedOffset
    }
}
