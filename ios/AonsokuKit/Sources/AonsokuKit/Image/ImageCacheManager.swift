import Foundation
import GRDB

public extension Notification.Name {
    static let aonsokuCoverImageCached = Notification.Name("AonsokuCoverImageCached")
}

public enum ImageCacheNotification {
    public static let coverArtIdKey = "coverArtId"
}

final class ImageCacheManager: @unchecked Sendable {
    private static let publication = ImageCachePublicationState()

    private let db: DatabasePool
    private let client: HTTPClient
    private let credentialsProvider: @Sendable () -> ServerCredentials?

    convenience init(db: DatabasePool) {
        self.init(
            db: db,
            client: NetworkService.shared.client(for: .artwork),
            credentialsProvider: { KeychainManager.retrieve() }
        )
    }

    convenience init(
        db: DatabasePool,
        session: URLSession,
        credentialsProvider: @escaping @Sendable () -> ServerCredentials?
    ) {
        self.init(db: db, client: HTTPClient(session: session), credentialsProvider: credentialsProvider)
    }

    init(
        db: DatabasePool,
        client: HTTPClient,
        credentialsProvider: @escaping @Sendable () -> ServerCredentials?
    ) {
        self.db = db
        self.client = client
        self.credentialsProvider = credentialsProvider
    }

    // MARK: - Public API

    func downloadAvatar(username: String, size: String) async throws -> URL {
        let publication = publicationToken(for: username)
        guard let credentials = credentialsProvider() else {
            throw ImageCacheError.noCredentials
        }

        let directory = try ImageCacheUtils.cacheDirectoryURL(createIfNeeded: true)
        let url = try buildAvatarURL(credentials: credentials, username: username, size: size)
        let (data, response) = try await client.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
            throw ImageCacheError.downloadFailed(NSError(domain: "ImageCache", code: -1))
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
        return try publishCoverImage(
            coverArtId: username,
            data: data,
            contentType: contentType,
            coverSize: size,
            directory: directory,
            expectedPublication: publication
        )
        .url
    }

    func downloadCoverImage(
        coverArtId: String,
        size: String,
        expectedPublication: ImageCachePublicationToken? = nil
    ) async throws -> URL {
        let requestPublication = expectedPublication ?? publicationToken(for: coverArtId)
        guard let credentials = credentialsProvider() else {
            throw ImageCacheError.noCredentials
        }

        let directory = try ImageCacheUtils.cacheDirectoryURL(createIfNeeded: true)

        let url = try buildCoverArtURL(credentials: credentials, coverArtId: coverArtId, size: size)
        let (data, response) = try await client.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
            throw ImageCacheError.downloadFailed(NSError(domain: "ImageCache", code: -1))
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
        let publication = try publishCoverImage(
            coverArtId: coverArtId,
            data: data,
            contentType: contentType,
            coverSize: size,
            directory: directory,
            expectedPublication: requestPublication
        )
        if publication.didWrite {
            notifyCoverImageCached(coverArtId: coverArtId)
        }

        return publication.url
    }

    func storeCoverImage(
        coverArtId: String,
        data: Data,
        contentType: String,
        coverSize: String,
        expectedPublication: ImageCachePublicationToken? = nil
    ) throws -> URL {
        let directory = try ImageCacheUtils.cacheDirectoryURL(createIfNeeded: true)
        let publication = try publishCoverImage(
            coverArtId: coverArtId,
            data: data,
            contentType: contentType,
            coverSize: coverSize,
            directory: directory,
            expectedPublication: expectedPublication
        )
        if publication.didWrite {
            notifyCoverImageCached(coverArtId: coverArtId)
        }
        return publication.url
    }

    private func publishCoverImage(
        coverArtId: String,
        data: Data,
        contentType: String,
        coverSize: String,
        directory: URL,
        expectedPublication: ImageCachePublicationToken? = nil
    ) throws -> (url: URL, didWrite: Bool) {
        Self.publication.lock.lock()
        defer { Self.publication.lock.unlock() }
        if let expectedPublication,
           expectedPublication != Self.publication.token(for: coverArtId) {
            throw CancellationError()
        }

        let cacheId = ImageCacheUtils.cacheId(for: coverArtId)
        let key = "cover:\(coverArtId)"
        let repo = CacheMetaRepository(db: db)
        if let incomingSize = Int(coverSize),
           let existingSizeString = try repo.getByKey(key)?.coverSize,
           let existingSize = Int(existingSizeString),
           existingSize > incomingSize,
           let existingURL = try findCoverImageURL(
               cacheId: cacheId,
               in: directory
           ),
           FileManager.default.fileExists(atPath: existingURL.path) {
            return (existingURL, false)
        }

        let ext = ImageCacheUtils.fileExtension(for: contentType)
        let fileName = "\(cacheId).\(ext)"
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)

        try data.write(to: fileURL, options: [.atomic])

        let now = Int(Date().timeIntervalSince1970 * 1000)
        let record = CacheMetaRecord(
            key: key,
            id: coverArtId,
            type: "cover",
            source: "explicit",
            triggersJson: nil,
            coverSize: coverSize,
            sizeBytes: data.count,
            cachedAt: now,
            lastAccessedAt: now,
            removedFromServer: nil
        )

        try repo.upsert(record)
        removeCoverImageFiles(
            cacheId: cacheId,
            in: directory,
            excluding: fileURL
        )

        return (fileURL, true)
    }

    func resolveCoverImage(coverArtId: String) -> URL? {
        guard let directory = try? ImageCacheUtils.cacheDirectoryURL(createIfNeeded: false) else {
            return nil
        }

        let cacheId = ImageCacheUtils.cacheId(for: coverArtId)
        guard let fileURL = try? findCoverImageURL(cacheId: cacheId, in: directory) else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Update lastAccessedAt asynchronously (best effort)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let key = "cover:\(coverArtId)"
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try? self.db.write { db in
                try CacheMetaRecord
                    .filter(Column("key") == key)
                    .updateAll(db, Column("lastAccessedAt").set(to: now))
            }
        }

        return fileURL
    }

    func deleteCoverImage(coverArtId: String) throws -> Bool {
        Self.publication.lock.lock()
        defer { Self.publication.lock.unlock() }
        Self.publication.itemGenerations[coverArtId, default: 0] &+= 1

        var deleted = false
        if let directory = try? ImageCacheUtils.cacheDirectoryURL(createIfNeeded: false),
           FileManager.default.fileExists(atPath: directory.path) {
            let cacheId = ImageCacheUtils.cacheId(for: coverArtId)
            deleted = removeCoverImageFiles(cacheId: cacheId, in: directory)
        }

        let key = "cover:\(coverArtId)"
        let repo = CacheMetaRepository(db: db)
        try repo.delete(key: key)

        return deleted
    }

    func clearCoverImages() throws -> Int {
        Self.publication.lock.lock()
        defer { Self.publication.lock.unlock() }
        Self.publication.clearGeneration &+= 1
        Self.publication.itemGenerations.removeAll(keepingCapacity: true)

        var deletedCount = 0
        if let directory = try? ImageCacheUtils.cacheDirectoryURL(createIfNeeded: false),
           FileManager.default.fileExists(atPath: directory.path) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )

            for url in urls {
                try FileManager.default.removeItem(at: url)
                deletedCount += 1
            }
        }

        try db.write { db in
            try CacheMetaRecord
                .filter(Column("type") == "cover")
                .deleteAll(db)
        }

        return deletedCount
    }

    func getCoverImageSize(coverArtId: String) -> (sizeBytes: Int, coverSize: String?)? {
        guard let directory = try? ImageCacheUtils.cacheDirectoryURL(createIfNeeded: false),
              let fileURL = try? findCoverImageURL(
                  cacheId: ImageCacheUtils.cacheId(for: coverArtId),
                  in: directory
              ),
              FileManager.default.fileExists(atPath: fileURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }

        let key = "cover:\(coverArtId)"
        let record = try? CacheMetaRepository(db: db).getByKey(key)

        return (sizeBytes: size.intValue, coverSize: record?.coverSize)
    }

    // MARK: - Private Helpers

    private func notifyCoverImageCached(coverArtId: String) {
        NativeLogger.shared.info(
            "cover cached; posting notification coverArtId=\(coverArtId)",
            source: "ImageCache"
        )
        NotificationCenter.default.post(
            name: .aonsokuCoverImageCached,
            object: nil,
            userInfo: [ImageCacheNotification.coverArtIdKey: coverArtId]
        )
    }

    func publicationToken(for coverArtId: String) -> ImageCachePublicationToken {
        Self.publication.lock.lock()
        defer { Self.publication.lock.unlock() }
        return Self.publication.token(for: coverArtId)
    }

    private func buildAvatarURL(credentials: ServerCredentials, username: String, size: String) throws -> URL {
        var params = SubsonicAuthBuilder.buildQueryParams(
            username: credentials.username,
            password: credentials.password,
            authType: credentials.authType,
            protocolVersion: credentials.protocolVersion
        )
        params["username"] = username
        params["size"] = size

        let baseString = "\(credentials.serverUrl)/rest/getAvatar"
        guard var components = URLComponents(string: baseString) else {
            throw ImageCacheError.invalidURL
        }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw ImageCacheError.invalidURL
        }
        return url
    }

    private func buildCoverArtURL(credentials: ServerCredentials, coverArtId: String, size: String) throws -> URL {
        var params = SubsonicAuthBuilder.buildQueryParams(
            username: credentials.username,
            password: credentials.password,
            authType: credentials.authType,
            protocolVersion: credentials.protocolVersion
        )
        params["id"] = coverArtId
        params["size"] = size

        let baseString = "\(credentials.serverUrl)/rest/getCoverArt"
        guard var components = URLComponents(string: baseString) else {
            throw ImageCacheError.invalidURL
        }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw ImageCacheError.invalidURL
        }
        return url
    }

    private func findCoverImageURL(cacheId: String, in directory: URL) throws -> URL? {
        ImageCacheUtils.coverImageURL(in: directory, cacheId: cacheId)
    }

    @discardableResult
    private func removeCoverImageFiles(
        cacheId: String,
        in directory: URL,
        excluding preservedURL: URL? = nil
    ) -> Bool {
        ImageCacheUtils.removeCoverImageFiles(
            in: directory,
            cacheId: cacheId,
            excluding: preservedURL
        )
    }
}

private final class ImageCachePublicationState: @unchecked Sendable {
    let lock = NSLock()
    var clearGeneration: UInt64 = 0
    var itemGenerations: [String: UInt64] = [:]

    func token(for coverArtId: String) -> ImageCachePublicationToken {
        ImageCachePublicationToken(
            clearGeneration: clearGeneration,
            itemGeneration: itemGenerations[coverArtId, default: 0]
        )
    }
}

struct ImageCachePublicationToken: Equatable, Sendable {
    let clearGeneration: UInt64
    let itemGeneration: UInt64
}
