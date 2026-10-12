package github.realtvop.aonsoku.plugins.data.sync

import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicHttpClient
import github.realtvop.aonsoku.plugins.data.db.dao.*
import github.realtvop.aonsoku.plugins.data.db.entity.*
import github.realtvop.aonsoku.plugins.debug.NativeLogger
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale

class SyncEngine(
    private val httpClient: SubsonicHttpClient,
    private val artistDao: ArtistDao,
    private val albumDao: AlbumDao,
    private val songDao: SongDao,
    private val playlistDao: PlaylistDao,
    private val genreDao: GenreDao,
    private val syncStateDao: SyncStateDao,
) {
    @Volatile private var credentials: ServerCredentials? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var currentJob: Job? = null
    private var generation = 0L
    var onSyncStateChanged: ((Map<String, Any?>) -> Unit)? = null
    var onDataChanged: ((List<String>) -> Unit)? = null
    val isSyncing: Boolean get() = currentJob?.isActive == true

    fun updateCredentials(c: ServerCredentials) { credentials = c }
    fun syncAll(mode: String = "full") { val g = ++generation; currentJob?.cancel(); currentJob = scope.launch { performSync(g, mode) } }
    fun syncIncremental() { syncAll("incremental") }
    fun cancel() { currentJob?.cancel(); currentJob = null }
    fun cleanup() { scope.cancel() }

    private fun creds(): ServerCredentials = credentials ?: throw Exception("No credentials")

    private suspend fun performSync(gen: Long, mode: String) {
        try {
            emitState("idle", null, 0, 0)
            if (!shouldSkipTier(SyncTier.T1, mode)) { val c = creds(); runGenres(c); runPlaylists(c); runFavorites(c) }
            if (!coroutineContext.isActive) return
            if (!shouldSkipTier(SyncTier.T2, mode)) { val c = creds(); runArtists(c); runAlbums(c) }
            if (!coroutineContext.isActive) return
            if (!shouldSkipTier(SyncTier.T3, mode)) { val c = creds(); runSongs(c) }
            if (!coroutineContext.isActive) return
            syncStateDao.upsert(SyncStateEntity("full-sync", System.currentTimeMillis()))
            emitState("done", null, 0, 0)
        } catch (_: CancellationException) { emitState("cancelled", null, 0, 0) } catch (e: Exception) { NativeLogger.error("sync failed: ${e.message ?: "unknown"}", "sync-engine"); emitState("error", null, 0, 0) }
        if (generation == gen) currentJob = null
    }

    private suspend fun runGenres(c: ServerCredentials) {
        emitState("genres", "t1", 0, 0)
        val r = httpClient.request(c.serverUrl, "getGenres.view", c)
        val arr = r.data.optJSONObject("genres")?.optJSONArray("genre")
        genreDao.deleteAll()
        if (arr != null) for (i in 0 until arr.length()) {
            val item = arr.optJSONObject(i) ?: continue
            genreDao.insert(item.optString("value"), if (item.has("songCount")) item.optInt("songCount") else null, if (item.has("albumCount")) item.optInt("albumCount") else null)
        }
    }

    private suspend fun runPlaylists(c: ServerCredentials) {
        emitState("playlists", "t1", 0, 0)
        val r = httpClient.request(c.serverUrl, "getPlaylists.view", c)
        val arr = r.data.optJSONObject("playlists")?.optJSONArray("playlist")
        val playlists = mutableListOf<PlaylistEntity>()
        if (arr != null) for (i in 0 until arr.length()) {
            val item = arr.optJSONObject(i) ?: continue
            val id = item.optString("id", null) ?: continue; val name = item.optString("name", null) ?: continue
            playlists.add(PlaylistEntity(id, name, item.optString("comment", null), item.optInt("songCount", 0), item.optInt("duration", 0), item.optBoolean("public", false), item.optString("owner", null), item.optString("created", null), item.optString("changed", null), item.optString("coverArt", null), item.optString("starred", null), toEpoch(item.optString("starred", null))))
        }
        playlistDao.bulkUpsert(playlists)
        val pIds = playlists.map { it.id }.toSet(); val eIds = playlistDao.getAllDetailIds(); val rem = eIds.filter { it !in pIds }
        if (rem.isNotEmpty() && pIds.isNotEmpty() && rem.size < eIds.size) playlistDao.deleteDetails(rem)
        for (i in playlists.indices step 25) {
            val batch = playlists.subList(i, (i + 25).coerceAtMost(playlists.size))
            val details = mutableListOf<PlaylistDetailEntity>()
            for (p in batch) try {
                val dr = httpClient.request(c.serverUrl, "getPlaylist.view", c, mapOf("id" to p.id))
                val dp = dr.data.optJSONObject("playlist") ?: continue
                val eid = dp.optString("id", null) ?: continue; val en = dp.optString("name", null) ?: continue
                details.add(PlaylistDetailEntity(eid, en, dp.optString("comment", null), dp.optInt("songCount", 0), dp.optInt("duration", 0), dp.optBoolean("public", false), dp.optString("owner", null), dp.optString("created", null), dp.optString("changed", null), dp.optString("coverArt", null), dp.optString("starred", null), toEpoch(dp.optString("starred", null)), dp.optJSONArray("entry")?.toString() ?: "[]"))
            } catch (e: Exception) { NativeLogger.warn("playlist detail failed: ${p.id} ${e.message ?: "unknown"}", "sync-engine") }
            if (details.isNotEmpty()) playlistDao.bulkUpsertDetails(details)
        }
    }

    private suspend fun runFavorites(c: ServerCredentials) {
        emitState("favorites", "t1", 0, 0); val r = httpClient.request(c.serverUrl, "getStarred2.view", c)
        val arr = r.data.optJSONObject("starred2")?.optJSONArray("song"); val songs = mutableListOf<SongEntity>()
        if (arr != null) for (i in 0 until arr.length()) parseSong(arr.optJSONObject(i))?.let { songs.add(it) }
        val previouslyStarred = songDao.getStarredSongIds()
        val starredIdsOnServer = songs.map { it.id }.toSet()
        if (previouslyStarred.isNotEmpty() && starredIdsOnServer.isNotEmpty()) {
            val toUnstar = previouslyStarred.filter { it !in starredIdsOnServer }
            if (toUnstar.isNotEmpty()) {
                songDao.updateStarred(toUnstar, null, null)
            }
        }
        if (songs.isNotEmpty()) songDao.bulkUpsert(songs)
        syncStateDao.upsert(SyncStateEntity("tier:t1", System.currentTimeMillis()))
        onDataChanged?.invoke(listOf("playlists", "genres", "favorites", "songs"))
    }

    private suspend fun runArtists(c: ServerCredentials) {
        emitState("artists", "t2", 0, 0); val r = httpClient.request(c.serverUrl, "getArtists.view", c)
        val idx = r.data.optJSONObject("artists")?.optJSONArray("index"); val artists = mutableListOf<ArtistEntity>()
        if (idx != null) for (i in 0 until idx.length()) {
            val grp = idx.optJSONObject(i) ?: continue; val al = grp.optJSONArray("artist") ?: continue
            for (j in 0 until al.length()) {
                val item = al.optJSONObject(j) ?: continue; val aid = item.optString("id", null) ?: continue; val aname = item.optString("name", null) ?: continue
                artists.add(ArtistEntity(aid, aname, item.optInt("albumCount", 0), item.optString("coverArt", null), item.optString("artistImageUrl", null), item.optString("starred", null), toEpoch(item.optString("starred", null)), item.optString("musicBrainzId", null), item.optString("sortName", null)))
            }
        }
        artists.sortBy { it.name.lowercase() }; artistDao.deleteAll(); artistDao.bulkUpsert(artists)
    }

    private suspend fun runAlbums(c: ServerCredentials) {
        emitState("albums", "t2", 0, 0); var all = mutableListOf<AlbumEntity>(); var off = 0
        while (true) {
            val r = httpClient.request(c.serverUrl, "getAlbumList2.view", c, mapOf("type" to "alphabeticalByName", "size" to "500", "offset" to off.toString()))
            val arr = r.data.optJSONObject("albumList2")?.optJSONArray("album") ?: break; var cnt = 0
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue; val aid = item.optString("id", null) ?: continue; val an = item.optString("name", null) ?: continue
                all.add(AlbumEntity(aid, an, item.optString("artist", ""), item.optString("artistId", null), item.optString("coverArt", null), item.optInt("songCount", 0), item.optInt("duration", 0), if (item.has("year")) item.optInt("year") else null, item.optString("genre", null), item.optString("created", null), item.optString("played", null), if (item.has("playCount")) item.optInt("playCount") else null, item.optString("starred", null), toEpoch(item.optString("starred", null)))); cnt++
            }
            emitState("albums", "t2", all.size, 0); off += 500; if (cnt < 500) break
        }
        albumDao.deleteAll(); albumDao.bulkUpsert(all)
        syncStateDao.upsert(SyncStateEntity("tier:t2", System.currentTimeMillis()))
        onDataChanged?.invoke(listOf("artists", "albums"))
    }

    private suspend fun runSongs(c: ServerCredentials) {
        emitState("songs", "t3", 0, 0); var all = mutableListOf<SongEntity>(); var off = 0
        val searchAllQuery = buildAllSongsQuery(c.serverType)
        while (true) {
            val r = httpClient.request(c.serverUrl, "search3.view", c, mapOf("query" to searchAllQuery, "artistCount" to "0", "artistOffset" to "0", "albumCount" to "0", "albumOffset" to "0", "songCount" to "500", "songOffset" to off.toString()))
            val arr = r.data.optJSONObject("searchResult3")?.optJSONArray("song") ?: break; var cnt = 0
            for (i in 0 until arr.length()) { parseSong(arr.optJSONObject(i))?.let { all.add(it); cnt++ } }
            off += cnt; emitState("songs", "t3", all.size, 0); if (cnt < 500) break
        }
        songDao.bulkUpsert(all)
        if (all.isEmpty()) {
            NativeLogger.warn("songs sync returned 0 songs; skipping stale deletion", "sync-engine")
        } else {
            val serverIds = all.map { it.id }.toSet()
            val localIds = songDao.getAllIds()
            val staleIds = localIds.filter { it !in serverIds }
            val maxDeletions = ((all.size + 9) / 10).coerceAtLeast(1)
            when {
                staleIds.isEmpty() -> {
                    NativeLogger.info("songs sync stale check ok: server=${all.size}, local=${localIds.size}, stale=0", "sync-engine")
                }
                staleIds.size <= maxDeletions -> {
                    val deleted = songDao.deleteByIds(staleIds)
                    NativeLogger.info("songs sync deleted stale songs: deleted=$deleted, stale=${staleIds.size}, server=${all.size}, local=${localIds.size}", "sync-engine")
                }
                else -> {
                    NativeLogger.warn("songs sync skipped stale deletion: stale=${staleIds.size}, max=$maxDeletions, server=${all.size}, local=${localIds.size}, sample=${staleIds.take(5).joinToString(",")}", "sync-engine")
                }
            }
        }
        emitState("songs", "t3", all.size, all.size)
        syncStateDao.upsert(SyncStateEntity("tier:t3", System.currentTimeMillis()))
        onDataChanged?.invoke(listOf("songs", "favorites"))
    }

    private fun parseSong(item: JSONObject?): SongEntity? {
        if (item == null) return null; val id = item.optString("id", null) ?: return null; val t = item.optString("title", null) ?: return null
        return SongEntity(
            id = id,
            parent = item.optString("parent", null),
            title = t,
            album = item.optString("album", null),
            artist = item.optString("artist", null),
            track = if (item.has("track")) item.optInt("track") else null,
            year = if (item.has("year")) item.optInt("year") else null,
            genre = item.optString("genre", null),
            coverArt = item.optString("coverArt", null),
            size = if (item.has("size")) item.optLong("size") else null,
            contentType = item.optString("contentType", null),
            suffix = item.optString("suffix", null),
            duration = item.optInt("duration", 0),
            bitRate = if (item.has("bitRate")) item.optInt("bitRate") else null,
            path = item.optString("path", null),
            playCount = if (item.has("playCount")) item.optInt("playCount") else null,
            discNumber = if (item.has("discNumber")) item.optInt("discNumber") else null,
            created = item.optString("created", null),
            albumId = item.optString("albumId", null),
            artistId = item.optString("artistId", null),
            played = item.optString("played", null),
            starred = item.optString("starred", null),
            starredAt = toEpoch(item.optString("starred", null)),
            playedAt = toEpoch(item.optString("playedAt", null)),
            bpm = if (item.has("bpm")) item.optInt("bpm") else null,
            comment = item.optString("comment", null),
            sortName = item.optString("sortName", null),
            mediaType = item.optString("mediaType", null),
            musicBrainzId = item.optString("musicBrainzId", null),
            genresJson = item.optJSONArray("genres")?.toString(),
            replayGainJson = item.optJSONObject("replayGain")?.toString()
        )
    }

    private suspend fun shouldSkipTier(tier: SyncTier, mode: String): Boolean {
        if (mode == "full") return false; val last = syncStateDao.getLastSyncedAt("tier:${tier.name.lowercase()}") ?: return false
        return (System.currentTimeMillis() - last) < tier.freshWindowMs
    }

    private fun emitState(phase: String, tier: String?, processed: Int, total: Int) {
        onSyncStateChanged?.invoke(mapOf("phase" to phase, "tier" to tier, "isSyncing" to (phase !in listOf("done", "error", "cancelled")), "progress" to if (total > 0) ((processed.toDouble() / total) * 100).toInt() else 0, "processedItems" to processed, "totalItems" to total))
    }

    private fun toEpoch(iso: String?): Long? {
        if (iso.isNullOrEmpty()) return null
        return try { SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }.parse(iso)?.time } catch (_: Exception) { try { SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }.parse(iso)?.time } catch (_: Exception) { null } }
    }
}

internal fun buildAllSongsQuery(serverType: String): String =
    if (serverType == "navidrome") "\"\"" else ""
