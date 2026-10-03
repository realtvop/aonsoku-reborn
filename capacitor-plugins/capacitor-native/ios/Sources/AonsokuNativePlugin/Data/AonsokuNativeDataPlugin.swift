import Foundation
import Capacitor

@objc(AonsokuNativeDataPlugin)
public class AonsokuNativeDataPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AonsokuNativeDataPlugin"
    public let jsName = "AonsokuNativeData"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "initialize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "importBulk", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncAll", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncIncremental", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelSync", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSyncState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getArtists", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getArtist", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAlbums", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAlbum", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSongs", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPlaylists", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPlaylist", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getGenres", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getFavorites", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "search", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLyrics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "storeLyrics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCacheStats", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isDataAvailableOffline", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "storeCoverImage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveCoverImage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCoverImageSize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteCoverImage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCoverImages", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadCoverImage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadAvatar", returnType: CAPPluginReturnPromise),
    ]

    private var eventEmitter: EventEmitter!
    private let libraryService = AppServices.shared.library
    private var libraryEventToken: UUID?
    private let dataQueue = DispatchQueue(label: "com.aonsoku.data.query", qos: .userInitiated, attributes: .concurrent)

    // MARK: - Initialization

    @objc func initialize(_ call: CAPPluginCall) {
        eventEmitter = EventEmitter(plugin: self)
        if libraryEventToken == nil {
            libraryEventToken = libraryService.subscribe { [weak self] event in
                DispatchQueue.main.async {
                    switch event {
                    case .syncStateChanged(let state):
                        self?.eventEmitter.emitSyncStateChanged([
                            "phase": state.phase,
                            "tier": state.tier as Any,
                            "isSyncing": state.isSyncing,
                            "processedItems": state.processedItems,
                            "totalItems": state.totalItems,
                        ])
                    case .dataChanged(let tables):
                        self?.eventEmitter.emitDataChanged(tables: tables, tier: "")
                    }
                }
            }
        }
        let initialization = libraryService.initialize()

        call.resolve([
            "ready": initialization.ready,
            "needsMigration": initialization.needsMigration,
        ])
    }

    @objc func importBulk(_ call: CAPPluginCall) {
        // Will be implemented in Phase 4 (frontend integration)
        call.resolve()
    }

    // MARK: - Sync Control

    @objc func syncAll(_ call: CAPPluginCall) {
        libraryService.syncAll()
        call.resolve()
    }

    @objc func syncIncremental(_ call: CAPPluginCall) {
        libraryService.syncIncremental()
        call.resolve()
    }

    @objc func cancelSync(_ call: CAPPluginCall) {
        libraryService.cancelSync()
        call.resolve()
    }

    @objc func getSyncState(_ call: CAPPluginCall) {
        call.resolve([
            "phase": "idle",
            "isSyncing": libraryService.isSyncing,
            "progress": 0,
            "processedItems": 0,
            "totalItems": 0,
        ])
    }

    // MARK: - Data Queries

    @objc func getArtists(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 100
        let offset = call.getInt("offset") ?? 0
        let filter = LibraryArtistFilter(
            search: call.getString("search"),
            starredOnly: call.getBool("starredOnly"),
            sortBy: call.getString("sortBy"),
            sortOrder: call.getString("sortOrder")
        )

        dataQueue.async {
            do {
                let page = try self.libraryService.artists(
                    limit: limit,
                    offset: offset,
                    filter: filter
                )
                call.resolve([
                    "items": page.items.map(Self.dictionary),
                    "total": page.total,
                    "hasMore": page.hasMore,
                ])
            } catch {
                call.reject("Failed to query artists: \(error.localizedDescription)")
            }
        }
    }

    @objc func getArtist(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Missing id parameter")
            return
        }
        dataQueue.async {
            do {
                if let artist = try self.libraryService.artist(id: id) {
                    call.resolve(Self.dictionary(artist))
                } else {
                    call.resolve([:])
                }
            } catch {
                call.reject("Failed to get artist: \(error.localizedDescription)")
            }
        }
    }

    @objc func getAlbums(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 100
        let offset = call.getInt("offset") ?? 0
        let filter = LibraryAlbumFilter(
            search: call.getString("search"),
            artistId: call.getString("artistId"),
            genre: call.getString("genre"),
            fromYear: call.getInt("fromYear"),
            toYear: call.getInt("toYear"),
            starredOnly: call.getBool("starredOnly"),
            sortBy: call.getString("sortBy"),
            sortOrder: call.getString("sortOrder")
        )

        dataQueue.async {
            do {
                let page = try self.libraryService.albums(
                    limit: limit,
                    offset: offset,
                    filter: filter
                )
                call.resolve([
                    "items": page.items.map(Self.dictionary),
                    "total": page.total,
                    "hasMore": page.hasMore,
                ])
            } catch {
                call.reject("Failed to query albums: \(error.localizedDescription)")
            }
        }
    }

    @objc func getAlbum(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Missing id parameter")
            return
        }
        dataQueue.async {
            do {
                if let result = try self.libraryService.album(id: id) {
                    var dict = Self.dictionary(result.album)
                    dict["song"] = result.songs.map(Self.dictionary)
                    call.resolve(dict)
                } else {
                    call.resolve([:])
                }
            } catch {
                call.reject("Failed to get album: \(error.localizedDescription)")
            }
        }
    }

    @objc func getSongs(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 100
        let offset = call.getInt("offset") ?? 0
        let filter = LibrarySongFilter(
            search: call.getString("search"),
            albumId: call.getString("albumId"),
            artistId: call.getString("artistId"),
            genre: call.getString("genre"),
            starredOnly: call.getBool("starredOnly"),
            sortBy: call.getString("sortBy"),
            sortOrder: call.getString("sortOrder")
        )

        dataQueue.async {
            do {
                let page = try self.libraryService.songs(
                    limit: limit,
                    offset: offset,
                    filter: filter
                )
                call.resolve([
                    "items": page.items.map(Self.dictionary),
                    "total": page.total,
                    "hasMore": page.hasMore,
                ])
            } catch {
                call.reject("Failed to query songs: \(error.localizedDescription)")
            }
        }
    }

    @objc func getPlaylists(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 100
        let offset = call.getInt("offset") ?? 0

        dataQueue.async {
            do {
                let page = try self.libraryService.playlists(
                    limit: limit,
                    offset: offset
                )
                call.resolve([
                    "items": page.items.map(Self.dictionary),
                    "total": page.total,
                    "hasMore": page.hasMore,
                ])
            } catch {
                call.reject("Failed to query playlists: \(error.localizedDescription)")
            }
        }
    }

    @objc func getPlaylist(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Missing id parameter")
            return
        }
        dataQueue.async {
            do {
                if let detail = try self.libraryService.playlist(id: id) {
                    var dictionary = Self.dictionary(detail.playlist)
                    if let data = detail.entriesJSON.data(using: .utf8),
                       let entries = try? JSONSerialization.jsonObject(with: data) {
                        dictionary["entry"] = entries
                    }
                    call.resolve(dictionary)
                } else {
                    call.resolve([:])
                }
            } catch {
                call.reject("Failed to get playlist: \(error.localizedDescription)")
            }
        }
    }

    @objc func getGenres(_ call: CAPPluginCall) {
        dataQueue.async {
            do {
                let items = try self.libraryService.genres()
                call.resolve([
                    "items": items.map(Self.dictionary),
                ])
            } catch {
                call.reject("Failed to query genres: \(error.localizedDescription)")
            }
        }
    }

    @objc func getFavorites(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 100
        let offset = call.getInt("offset") ?? 0
        let type = call.getString("type") ?? "songs"

        dataQueue.async {
            do {
                switch type {
                case "artists":
                    let page = try self.libraryService.artists(
                        limit: limit,
                        offset: offset,
                        filter: LibraryArtistFilter(
                            starredOnly: true,
                            sortBy: "starredAt",
                            sortOrder: "desc"
                        )
                    )
                    call.resolve([
                        "items": page.items.map(Self.dictionary),
                        "total": page.total,
                        "hasMore": page.hasMore,
                    ])
                case "albums":
                    let page = try self.libraryService.albums(
                        limit: limit,
                        offset: offset,
                        filter: LibraryAlbumFilter(
                            starredOnly: true,
                            sortBy: "starredAt",
                            sortOrder: "desc"
                        )
                    )
                    call.resolve([
                        "items": page.items.map(Self.dictionary),
                        "total": page.total,
                        "hasMore": page.hasMore,
                    ])
                default:
                    let page = try self.libraryService.songs(
                        limit: limit,
                        offset: offset,
                        filter: LibrarySongFilter(
                            starredOnly: true,
                            sortBy: "starredAt",
                            sortOrder: "desc"
                        )
                    )
                    call.resolve([
                        "items": page.items.map(Self.dictionary),
                        "total": page.total,
                        "hasMore": page.hasMore,
                    ])
                }
            } catch {
                call.reject("Failed to query favorites: \(error.localizedDescription)")
            }
        }
    }

    @objc func search(_ call: CAPPluginCall) {
        guard let query = call.getString("query"), !query.isEmpty else {
            call.resolve(["artists": [], "albums": [], "songs": []])
            return
        }

        let artistCount = call.getInt("artistCount") ?? 20
        let albumCount = call.getInt("albumCount") ?? 20
        let songCount = call.getInt("songCount") ?? 20

        dataQueue.async {
            do {
                let result = try self.libraryService.search(
                    query: query,
                    artistCount: artistCount,
                    albumCount: albumCount,
                    songCount: songCount
                )
                call.resolve([
                    "artists": result.artists.map(Self.dictionary),
                    "albums": result.albums.map(Self.dictionary),
                    "songs": result.songs.map(Self.dictionary),
                ])
            } catch {
                call.reject("Failed to search: \(error.localizedDescription)")
            }
        }
    }

    @objc func getLyrics(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId") else {
            call.reject("Missing songId parameter")
            return
        }
        dataQueue.async {
            do {
                if let lyrics = try self.libraryService.lyrics(songId: songId) {
                    call.resolve(Self.dictionary(lyrics))
                } else {
                    call.resolve([:])
                }
            } catch {
                call.reject("Failed to get lyrics: \(error.localizedDescription)")
            }
        }
    }

    @objc func storeLyrics(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId"),
              let content = call.getString("content") else {
            call.reject("Missing required parameters")
            return
        }
        let synced = call.getBool("synced") ?? false
        dataQueue.async {
            do {
                try self.libraryService.storeLyrics(
                    songId: songId,
                    content: content,
                    synced: synced
                )
                call.resolve()
            } catch {
                call.reject("Failed to store lyrics: \(error.localizedDescription)")
            }
        }
    }

    @objc func getCacheStats(_ call: CAPPluginCall) {
        dataQueue.async {
            do {
                let stats = try self.libraryService.cacheStats()
                call.resolve([
                    "totalItems": stats.totalItems,
                    "totalSizeBytes": stats.totalSizeBytes,
                    "audioCount": stats.audioCount,
                    "coverCount": stats.coverCount,
                ])
            } catch {
                call.reject("Failed to get cache stats: \(error.localizedDescription)")
            }
        }
    }

    @objc func isDataAvailableOffline(_ call: CAPPluginCall) {
        dataQueue.async {
            let availability = self.libraryService.availability()
            call.resolve([
                "available": availability.available,
                "lastSyncedAt": availability.lastSyncedAt as Any,
            ])
        }
    }

    // MARK: - Cover Image Cache

    @objc func storeCoverImage(_ call: CAPPluginCall) {
        guard let coverArtId = call.getString("coverArtId"), !coverArtId.isEmpty else {
            call.reject("Missing coverArtId")
            return
        }
        guard let dataBase64 = call.getString("dataBase64"), !dataBase64.isEmpty else {
            call.reject("Missing dataBase64")
            return
        }
        let contentType = call.getString("contentType") ?? "image/jpeg"
        let coverSize = call.getString("coverSize") ?? "700"

        DispatchQueue.global(qos: .utility).async {
            do {
                guard let data = Data(base64Encoded: dataBase64) else {
                    call.reject("Invalid base64 data")
                    return
                }
                let file = try self.libraryService.storeCover(
                    id: coverArtId,
                    data: data,
                    contentType: contentType,
                    size: coverSize
                )
                DispatchQueue.main.async {
                    call.resolve(["file": Self.fileDictionary(file)])
                }
            } catch {
                DispatchQueue.main.async {
                    call.reject("Failed to store cover image: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func resolveCoverImage(_ call: CAPPluginCall) {
        guard let coverArtId = call.getString("coverArtId"), !coverArtId.isEmpty else {
            call.reject("Missing coverArtId")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            guard let file = self.libraryService.resolveCover(
                id: coverArtId,
                requestedSize: ""
            ) else {
                DispatchQueue.main.async {
                    call.resolve(["file": NSNull()])
                }
                return
            }

            DispatchQueue.main.async {
                var dictionary = Self.fileDictionary(file)
                dictionary.removeValue(forKey: "coverSize")
                call.resolve(["file": dictionary])
            }
        }
    }

    @objc func getCoverImageSize(_ call: CAPPluginCall) {
        guard let coverArtId = call.getString("coverArtId"), !coverArtId.isEmpty else {
            call.reject("Missing coverArtId")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let result = self.libraryService.coverSize(id: coverArtId)
            DispatchQueue.main.async {
                call.resolve([
                    "sizeBytes": result.map { NSNumber(value: $0.sizeBytes) } ?? NSNull(),
                    "coverSize": result?.coverSize ?? NSNull(),
                ])
            }
        }
    }

    @objc func deleteCoverImage(_ call: CAPPluginCall) {
        guard let coverArtId = call.getString("coverArtId"), !coverArtId.isEmpty else {
            call.reject("Missing coverArtId")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let deleted = try self.libraryService.deleteCover(id: coverArtId)
                DispatchQueue.main.async {
                    call.resolve(["deleted": deleted])
                }
            } catch {
                DispatchQueue.main.async {
                    call.reject("Failed to delete cover image: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func clearCoverImages(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let deletedCount = try self.libraryService.clearCovers()
                DispatchQueue.main.async {
                    call.resolve(["deletedCount": deletedCount])
                }
            } catch {
                DispatchQueue.main.async {
                    call.reject("Failed to clear cover images: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func downloadAvatar(_ call: CAPPluginCall) {
        guard let username = call.getString("username"), !username.isEmpty else {
            call.reject("Missing username")
            return
        }
        let size = call.getString("size") ?? "150"

        Task {
            do {
                let file = try await self.libraryService.downloadAvatar(
                    username: username,
                    size: size
                )
                call.resolve(["file": Self.fileDictionary(file)])
            } catch {
                call.reject("Failed to download avatar: \(error.localizedDescription)")
            }
        }
    }

    @objc func downloadCoverImage(_ call: CAPPluginCall) {
        guard let coverArtId = call.getString("coverArtId"), !coverArtId.isEmpty else {
            call.reject("Missing coverArtId")
            return
        }
        let size = call.getString("size") ?? "700"

        Task {
            do {
                let file = try await self.libraryService.downloadCover(
                    id: coverArtId,
                    size: size
                )
                call.resolve(["file": Self.fileDictionary(file)])
            } catch {
                call.reject("Failed to download cover image: \(error.localizedDescription)")
            }
        }
    }

    private static func dictionary<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private static func fileDictionary(_ file: LibraryCachedImage) -> [String: Any] {
        [
            "coverArtId": file.id,
            "uri": file.uri,
            "contentType": file.contentType as Any,
            "sizeBytes": file.sizeBytes as Any,
            "coverSize": file.requestedSize,
        ]
    }
}
