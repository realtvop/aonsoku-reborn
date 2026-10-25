import Foundation

class NativeSourceResolver {
    let cacheDirectories: [URL]
    private let fileManager: FileManager
    private let credentialsProvider: () -> ServerCredentials?
    private let estimateContentLengthProvider: () -> Bool
    private let now: () -> Date
    private var cachedCredentials: ServerCredentials?
    private var credentialsCacheTime: Date?
    private let credentialsTTL: TimeInterval
    private let cacheLock = NSLock()
    private var rejectedCachedFiles = Set<URL>()

    init(
        cacheDirectories: [URL]? = nil,
        fileManager: FileManager = .default,
        credentialsProvider: @escaping () -> ServerCredentials? = {
            KeychainManager.retrieve()
        },
        estimateContentLengthProvider: @escaping () -> Bool = {
            PreferencesService.shared.estimateStreamContentLength
        },
        now: @escaping () -> Date = Date.init,
        credentialsTTL: TimeInterval = 30
    ) {
        self.fileManager = fileManager
        self.credentialsProvider = credentialsProvider
        self.estimateContentLengthProvider = estimateContentLengthProvider
        self.now = now
        self.credentialsTTL = credentialsTTL
        if let cacheDirectories {
            self.cacheDirectories = cacheDirectories
            return
        }
        var dirs: [URL] = []

        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        dirs.append(
            appSupport
                .appendingPathComponent("Aonsoku", isDirectory: true)
                .appendingPathComponent("AudioCache", isDirectory: true)
        )

        if let documents = fileManager.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            dirs.append(
                documents.appendingPathComponent("AudioCache", isDirectory: true)
            )
        }

        self.cacheDirectories = dirs
    }

    func invalidateCredentialsCache() {
        cachedCredentials = nil
        credentialsCacheTime = nil
    }

    private func getCredentials() -> ServerCredentials? {
        if let cached = cachedCredentials,
           let cacheTime = credentialsCacheTime,
           now().timeIntervalSince(cacheTime) < credentialsTTL {
            return cached
        }
        let creds = credentialsProvider()
        cachedCredentials = creds
        credentialsCacheTime = now()
        return creds
    }

    func resolveSource(for song: QueueSong) -> (url: URL, kind: String)? {
        if let fileUrl = cachedFile(songId: song.id, explicitURI: song.cachedFileUri) {
            NativeLogger.shared.info(
                "SourceResolver: found cached file for \(song.id) at \(fileUrl.lastPathComponent)",
                source: "Audio"
            )
            return (fileUrl, "native-file")
        }
        NativeLogger.shared.debug("SourceResolver: no usable cache for \(song.id)", source: "Audio")

        if song.streamUrl.hasPrefix("http://") ||
            song.streamUrl.hasPrefix("https://") {
            guard let streamUrl = URL(string: song.streamUrl) else { return nil }
            // Queues may retain authenticated URLs created before the user
            // changed this setting. Refresh only Subsonic stream endpoints;
            // arbitrary HTTP/radio URLs must pass through unchanged.
            return (updatingStreamOptions(in: streamUrl), "stream")
        }

        if song.streamUrl.hasPrefix("aonsoku-media://stream"),
           let components = URLComponents(string: song.streamUrl),
           let queryItems = components.queryItems {
            let values = Dictionary(
                queryItems.compactMap { item in
                    item.value.map { (item.name, $0) }
                },
                uniquingKeysWith: { _, last in last }
            )
            let songId = values["id"].flatMap { $0.isEmpty ? nil : $0 } ?? song.id
            var extra: [String: String] = [:]
            if let maxBitRate = values["maxBitRate"] {
                extra["maxBitRate"] = maxBitRate
            }
            if let format = values["format"] {
                extra["format"] = format
            }
            return buildAuthenticatedStreamUrl(songId: songId, extra: extra)
                .map { ($0, "stream") }
        }

        return nil
    }

    func cachedFile(songId: String, explicitURI: String? = nil) -> URL? {
        if let explicitURI, !explicitURI.isEmpty {
            let url = fileURL(from: explicitURI)
            if isUsableCachedFile(at: url) { return url }
        }
        let cacheId = cacheId(for: songId)
        for directory in cacheDirectories {
            for ext in ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "audio"] {
                let url = directory.appendingPathComponent("\(cacheId).\(ext)")
                if isUsableCachedFile(at: url) { return url }
            }
        }
        return nil
    }

    func isUsableCachedFile(at url: URL) -> Bool {
        guard url.isFileURL,
              !cacheLock.withLock({ rejectedCachedFiles.contains(url.standardizedFileURL) }),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    /// Exclude the failing source without deleting a user-provided local file.
    /// A completed replacement download makes its canonical cache URL usable again.
    func rejectCachedFile(at url: URL) {
        cacheLock.withLock { _ = rejectedCachedFiles.insert(url.standardizedFileURL) }
    }

    func acceptDownloadedFile(at url: URL) {
        cacheLock.withLock { _ = rejectedCachedFiles.remove(url.standardizedFileURL) }
    }

    func buildStreamUrl(songId: String) -> String? {
        buildAuthenticatedStreamUrl(songId: songId, extra: [:])?.absoluteString
    }

    private func updatingStreamOptions(in url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/rest/stream") ||
                components.path.hasSuffix("/rest/stream.view") else { return url }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "estimateContentLength" }
        query.append(URLQueryItem(
            name: "estimateContentLength",
            value: String(estimateContentLengthProvider())
        ))
        components.queryItems = query
        return components.url ?? url
    }

    private func buildAuthenticatedStreamUrl(
        songId: String,
        extra: [String: String]
    ) -> URL? {
        guard let credentials = getCredentials() else { return nil }

        var params = SubsonicAuthBuilder.buildQueryParams(
            username: credentials.username,
            password: credentials.password,
            authType: credentials.authType,
            protocolVersion: credentials.protocolVersion
        )
        params["id"] = songId
        // This is a server hint, not a guarantee of HTTP Range support.
        params["estimateContentLength"] = String(estimateContentLengthProvider())
        for (key, value) in extra {
            params[key] = value
        }

        let baseUrl = credentials.serverUrl.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let baseString = "\(baseUrl)/rest/stream"
        guard var components = URLComponents(string: baseString) else { return nil }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    private func cacheId(for songId: String) -> String {
        AudioCacheUtils.cacheId(for: songId)
    }

    private func fileURL(from uri: String) -> URL {
        if let url = URL(string: uri), url.isFileURL {
            return url
        }

        return URL(fileURLWithPath: uri)
    }
}
