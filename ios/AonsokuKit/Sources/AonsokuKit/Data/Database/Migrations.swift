import Foundation
import GRDB

enum Migrations {
    static func registerAll(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.create(table: "artist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("albumCount", .integer).notNull().defaults(to: 0)
                t.column("coverArt", .text)
                t.column("artistImageUrl", .text)
                t.column("starred", .text)
                t.column("starredAt", .integer)
                t.column("musicBrainzId", .text)
                t.column("sortName", .text)
            }
            try db.create(index: "idx_artist_name", on: "artist", columns: ["name"])
            try db.create(index: "idx_artist_starredAt", on: "artist", columns: ["starredAt"])

            try db.create(table: "album") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("artistId", .text)
                t.column("coverArt", .text)
                t.column("songCount", .integer).notNull().defaults(to: 0)
                t.column("duration", .integer).notNull().defaults(to: 0)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("created", .text)
                t.column("played", .text)
                t.column("playCount", .integer)
                t.column("starred", .text)
                t.column("starredAt", .integer)
            }
            try db.create(index: "idx_album_artistId", on: "album", columns: ["artistId"])
            try db.create(index: "idx_album_name", on: "album", columns: ["name"])
            try db.create(index: "idx_album_year", on: "album", columns: ["year"])
            try db.create(index: "idx_album_genre", on: "album", columns: ["genre"])
            try db.create(index: "idx_album_starredAt", on: "album", columns: ["starredAt"])
            try db.create(index: "idx_album_created", on: "album", columns: ["created"])

            try db.create(table: "song") { t in
                t.primaryKey("id", .text)
                t.column("parent", .text)
                t.column("title", .text).notNull()
                t.column("album", .text)
                t.column("artist", .text)
                t.column("track", .integer)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("coverArt", .text)
                t.column("size", .integer)
                t.column("contentType", .text)
                t.column("suffix", .text)
                t.column("duration", .integer).notNull().defaults(to: 0)
                t.column("bitRate", .integer)
                t.column("path", .text)
                t.column("playCount", .integer)
                t.column("discNumber", .integer)
                t.column("created", .text)
                t.column("albumId", .text)
                t.column("artistId", .text)
                t.column("played", .text)
                t.column("starred", .text)
                t.column("starredAt", .integer)
                t.column("playedAt", .integer)
                t.column("bpm", .integer)
                t.column("comment", .text)
                t.column("sortName", .text)
                t.column("mediaType", .text)
                t.column("musicBrainzId", .text)
                t.column("genresJson", .text)
                t.column("replayGainJson", .text)
            }
            try db.create(index: "idx_song_albumId", on: "song", columns: ["albumId"])
            try db.create(index: "idx_song_artistId", on: "song", columns: ["artistId"])
            try db.create(index: "idx_song_title", on: "song", columns: ["title"])
            try db.create(index: "idx_song_starredAt", on: "song", columns: ["starredAt"])
            try db.create(index: "idx_song_playCount", on: "song", columns: ["playCount"])
            try db.create(index: "idx_song_playedAt", on: "song", columns: ["playedAt"])

            try db.create(table: "playlist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("comment", .text)
                t.column("songCount", .integer).notNull().defaults(to: 0)
                t.column("duration", .integer).notNull().defaults(to: 0)
                t.column("isPublic", .boolean).notNull().defaults(to: false)
                t.column("owner", .text)
                t.column("created", .text)
                t.column("changed", .text)
                t.column("coverArt", .text)
                t.column("starred", .text)
                t.column("starredAt", .integer)
            }
            try db.create(index: "idx_playlist_name", on: "playlist", columns: ["name"])
            try db.create(index: "idx_playlist_starredAt", on: "playlist", columns: ["starredAt"])

            try db.create(table: "playlistDetail") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("comment", .text)
                t.column("songCount", .integer).notNull().defaults(to: 0)
                t.column("duration", .integer).notNull().defaults(to: 0)
                t.column("isPublic", .boolean).notNull().defaults(to: false)
                t.column("owner", .text)
                t.column("created", .text)
                t.column("changed", .text)
                t.column("coverArt", .text)
                t.column("starred", .text)
                t.column("starredAt", .integer)
                t.column("entriesJson", .text).notNull()
            }

            try db.create(table: "genre") { t in
                t.primaryKey("value", .text)
                t.column("songCount", .integer)
                t.column("albumCount", .integer)
            }

            try db.create(table: "cacheMeta") { t in
                t.primaryKey("key", .text)
                t.column("id", .text).notNull()
                t.column("type", .text).notNull()
                t.column("source", .text).notNull()
                t.column("triggersJson", .text)
                t.column("coverSize", .text)
                t.column("sizeBytes", .integer).notNull()
                t.column("cachedAt", .integer).notNull()
                t.column("lastAccessedAt", .integer).notNull()
                t.column("removedFromServer", .boolean)
            }
            try db.create(index: "idx_cacheMeta_id", on: "cacheMeta", columns: ["id"])
            try db.create(index: "idx_cacheMeta_type", on: "cacheMeta", columns: ["type"])
            try db.create(index: "idx_cacheMeta_source", on: "cacheMeta", columns: ["source"])
            try db.create(index: "idx_cacheMeta_lastAccessedAt", on: "cacheMeta", columns: ["lastAccessedAt"])
            try db.create(index: "idx_cacheMeta_cachedAt", on: "cacheMeta", columns: ["cachedAt"])

            try db.create(table: "lyrics") { t in
                t.primaryKey("songId", .text)
                t.column("content", .text).notNull()
                t.column("synced", .boolean)
                t.column("cachedAt", .integer).notNull()
                t.column("lastAccessedAt", .integer).notNull()
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("lastSyncedAt", .integer)
                t.column("phase", .text)
                t.column("checkpointJson", .text)
            }
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "preferences") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updatedAt", .integer).notNull()
            }

            try db.create(table: "queueState") { t in
                t.primaryKey("key", .text)
                t.column("stateJson", .text).notNull()
                t.column("updatedAt", .integer).notNull()
            }

            try db.create(table: "playHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("songJson", .text).notNull()
                t.column("playedAt", .integer).notNull()
            }
            try db.create(
                index: "idx_playHistory_playedAt",
                on: "playHistory",
                columns: ["playedAt"]
            )
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "playbackState") { t in
                t.primaryKey("key", .text)
                t.column("stateJson", .text).notNull()
                t.column("currentTime", .double).notNull().defaults(to: 0)
                t.column("updatedAt", .integer).notNull()
            }
        }
    }
}
