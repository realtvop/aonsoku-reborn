import Foundation
import GRDB

extension Notification.Name {
    static let aonsokuCoverImageCached = Notification.Name("AonsokuCoverImageCached")
}

enum ImageCacheNotification {
    static let coverArtIdKey = "coverArtId"
}

final class ImageCacheManager {
    private let db: DatabasePool
    private let session: URLSession

    init(db: DatabasePool) {
        self.db = db
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    func downloadAvatar(username: String, size: String) async throws -> URL {
        guard let credentials = KeychainManager.retrieve() else {
            throw ImageCacheError.noCredentials
        }

        let directory = try ImageCacheUtils.cacheDirectoryURL(createIfNeeded: true)
        let cacheId = ImageCacheUtils.cacheId(for: username)
        // Remove existing file before downloading
        let existingFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("\(cacheId).") }
        for file in existingFiles {
            try? FileManager.default.removeItem(at: file)
        }

        let url = try buildAvatarURL(credentials: credentials, username: username, size: size)
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
            throw ImageCacheError.downloadFailed(NSError(domain: "ImageCache", code: -1))
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
        let ext = ImageCacheUtils.fileExtension(for: contentType)
        let fileName = "\(cacheId).\(ext)"
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)

        try data.write(to: fileURL, options: [.atomic])

        let now = Int(Date().timeIntervalSince1970 * 1000)
        let record = CacheMetaRecord(
            key: "cover:\(username)",
            id: username,
            type: "cover",
            source: "explicit",
            triggersJson: nil,
            coverSize: size,
            sizeBytes: data.count,
            cachedAt: now,
            lastAccessedAt: now,
            removedFromServer: nil
        )

        let repo = CacheMetaRepository(db: db)
        try repo.upsert(record)

        return fileURL
    }

    func downloadCoverImage(coverArtId: String, size: String) async throws -> URL {
        guard let credentials = KeychainManager.retrieve() else {
            throw ImageCacheError.noCredentials
        }

        let directory = try ImageCacheUtils.cacheDirectoryURL(createIfNeeded: true)

        removeCoverImageFiles(cacheId: ImageCacheUtils.cacheId(for: coverArtId), in: directory)

        let url = try buildCoverArtURL(credentials: credentials, coverArtId: coverArtId, size: size)
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
            throw ImageCacheError.downloadFailed(NSError(domain: "ImageCache", code: -1))
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
        let ext = ImageCacheUtils.fileExtension(for: contentType)
        let finalFileName = "\(ImageCacheUtils.cacheId(for: coverArtId)).\(ext)"
        let finalFileURL = directory.appendingPathComponent(finalFileName, isDirectory: false)

        try data.write(to: finalFileURL, options: [.atomic])

        let now = Int(Date().timeIntervalSince1970 * 1000)
        let record = CacheMetaRecord(
            key: "cover:\(coverArtId)",
            id: coverArtId,
            type: "cover",
            source: "explicit",
            triggersJson: nil,
            coverSize: size,
            sizeBytes: data.count,
            cachedAt: now,
            lastAccessedAt: now,
            removedFromServer: nil
        )

        let repo = CacheMetaRepository(db: db)
        try repo.upsert(record)
        notifyCoverImageCached(coverArtId: coverArtId)

        return finalFileURL
    }

    func storeCoverImage(coverArtId: String, data: Data, contentType: String, coverSize: String) throws -> URL {
        let directory = try ImageCacheUtils.cacheDirectoryURL(createIfNeeded: true)
        let ext = ImageCacheUtils.fileExtension(for: contentType)
        let fileName = "\(ImageCacheUtils.cacheId(for: coverArtId)).\(ext)"
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)

        removeCoverImageFiles(cacheId: ImageCacheUtils.cacheId(for: coverArtId), in: directory)

        try data.write(to: fileURL, options: [.atomic])

        let now = Int(Date().timeIntervalSince1970 * 1000)
        let record = CacheMetaRecord(
            key: "cover:\(coverArtId)",
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

        let repo = CacheMetaRepository(db: db)
        try repo.upsert(record)
        notifyCoverImageCached(coverArtId: coverArtId)

        return fileURL
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
        ImageCacheUtils.cachedImageExtensions
            .map { directory.appendingPathComponent("\(cacheId).\($0)", isDirectory: false) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    private func removeCoverImageFiles(cacheId: String, in directory: URL) -> Bool {
        var deleted = false
        for ext in ImageCacheUtils.cachedImageExtensions {
            let url = directory.appendingPathComponent("\(cacheId).\(ext)", isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                deleted = true
            } catch {}
        }
        return deleted
    }
}
