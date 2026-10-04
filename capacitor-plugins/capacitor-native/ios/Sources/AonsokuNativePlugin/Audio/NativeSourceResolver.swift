import Foundation

class NativeSourceResolver {
    let cacheDirectories: [URL]
    private let fileManager: FileManager
    private let credentialsProvider: () -> ServerCredentials?
    private let now: () -> Date
    private var cachedCredentials: ServerCredentials?
    private var credentialsCacheTime: Date?
    private let credentialsTTL: TimeInterval

    init(
        cacheDirectories: [URL]? = nil,
        fileManager: FileManager = .default,
        credentialsProvider: @escaping () -> ServerCredentials? = {
            KeychainManager.retrieve()
        },
        now: @escaping () -> Date = Date.init,
        credentialsTTL: TimeInterval = 30
    ) {
        self.fileManager = fileManager
        self.credentialsProvider = credentialsProvider
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
        if let cachedUri = song.cachedFileUri, !cachedUri.isEmpty {
            let fileUrl = fileURL(from: cachedUri)
            if fileManager.fileExists(atPath: fileUrl.path) {
                return (fileUrl, "native-file")
            }
        }

        let cacheId = cacheId(for: song.id)
        let extensions = ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "audio"]
        for directory in cacheDirectories {
            guard fileManager.fileExists(atPath: directory.path) else {
                NativeLogger.shared.debug("SourceResolver: directory not found: \(directory.path)", source: "Audio")
                continue
            }
            for ext in extensions {
                let fileUrl = directory.appendingPathComponent("\(cacheId).\(ext)")
                if fileManager.fileExists(atPath: fileUrl.path) {
                    NativeLogger.shared.info("SourceResolver: found cached file for \(song.id) at \(fileUrl.lastPathComponent)", source: "Audio")
                    return (fileUrl, "native-file")
                }
            }
        }
        NativeLogger.shared.debug("SourceResolver: no cache hit for \(song.id), cacheId=\(cacheId)", source: "Audio")

        if song.streamUrl.hasPrefix("http://") ||
            song.streamUrl.hasPrefix("https://") {
            guard let streamUrl = URL(string: song.streamUrl) else { return nil }
            return (streamUrl, "stream")
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

    func buildStreamUrl(songId: String) -> String? {
        buildAuthenticatedStreamUrl(songId: songId, extra: [:])?.absoluteString
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
        // Must be "true" for native AVPlayer: without Content-Length, AVPlayer cannot
        // issue HTTP Range requests, causing buffer stalls and seek failures.
        // (Web uses "false" to work around browser-specific streaming quirks.)
        params["estimateContentLength"] = "true"
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
