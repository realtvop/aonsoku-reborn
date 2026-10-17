package github.realtvop.aonsoku.data.offline

import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.NetworkMonitor
import github.realtvop.aonsoku.data.image.ArtworkStore
import github.realtvop.aonsoku.data.lyrics.LyricsRepository
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.Translations
import github.realtvop.aonsoku.plugins.audio.AudioCacheEvent
import github.realtvop.aonsoku.plugins.audio.AudioCacheService
import github.realtvop.aonsoku.plugins.audio.AudioCacheSource
import github.realtvop.aonsoku.plugins.audio.AudioDownload
import github.realtvop.aonsoku.plugins.audio.CachedAudio
import github.realtvop.aonsoku.plugins.data.LibraryPagination
import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.settings.SettingsRepository
import github.realtvop.aonsoku.ui.components.Toaster
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicInteger

/**
 * Decides what is kept on the device: the user's downloads, the smart
 * downloads their rules ask for, and the library's images. The files, their
 * index, and the download queue belong to [AudioCacheService] and the image
 * cache of [LibraryService]; this class turns settings, the state of the
 * network, and what happens in the library into requests to them.
 */
class OfflineManager(
    private val cache: AudioCacheService,
    private val library: LibraryService,
    private val repository: LibraryRepository,
    private val settings: SettingsRepository,
    private val network: NetworkMonitor,
    private val artwork: ArtworkStore,
    private val lyrics: LyricsRepository,
    private val toaster: Toaster,
    private val strings: () -> Translations,
    private val scope: CoroutineScope,
) {
    private var session: Job? = null
    private var coverSyncJob: Job? = null
    private val smartPasses = Channel<Unit>(Channel.CONFLATED)
    private val coverStats = MutableStateFlow(PoolStats())
    private val _coverSync = MutableStateFlow<CoverSyncProgress?>(null)
    private val _pools = MutableStateFlow(CachePools())

    /** The audio kept on the device, by song id. */
    val cached: StateFlow<Map<String, CachedAudio>> = cache.cached

    /** The downloads that wait or run, by song id. */
    val downloads: StateFlow<Map<String, AudioDownload>> = cache.downloads

    /** Set while the images of the library are downloaded. */
    val coverSync: StateFlow<CoverSyncProgress?> = _coverSync.asStateFlow()

    val pools: StateFlow<CachePools> = _pools.asStateFlow()

    // region Session

    /** Starts keeping the cache in line with the settings; call when a session becomes active. */
    fun start() {
        session?.cancel()
        session = scope.launch {
            launch {
                combine(cache.cached, coverStats) { audio, covers -> pools(audio.values, covers) }
                    .collect { _pools.value = it }
            }
            launch {
                runSuspendCatching { cache.initialize() }
                refreshCoverStats()
            }
            launch {
                settings.state.map { it.cache.lruQuota }.distinctUntilChanged()
                    .collect { quota -> runSuspendCatching { cache.setLruQuota(quota) } }
            }
            launch {
                settings.state.map { it.cache.assetsQuota }.distinctUntilChanged().collect { trimCovers() }
            }
            launch {
                settings.state.map { it.cache.smartRules }.distinctUntilChanged().collect { smartPasses.trySend(Unit) }
            }
            launch {
                network.isOnline.collect { online ->
                    if (!online) return@collect
                    // What failed for want of a network gets another chance.
                    runSuspendCatching { cache.resume() }
                    smartPasses.trySend(Unit)
                }
            }
            launch {
                repository.changes.collect { change ->
                    if (change == LibraryChange.Favorites || change == LibraryChange.Playlists) {
                        smartPasses.trySend(Unit)
                    }
                }
            }
            launch { cache.events.collect(::onCacheEvent) }
            launch {
                for (pass in smartPasses) {
                    // Several changes in a row make one pass.
                    delay(SMART_PASS_DELAY_MS)
                    runSuspendCatching { syncSmartDownloads() }
                }
            }
        }
    }

    /**
     * Ends the session. Everything that was kept belongs to the account that
     * signed out, so it goes with it.
     */
    suspend fun end() {
        session?.cancel()
        session = null
        coverSyncJob?.cancel()
        _coverSync.value = null
        runSuspendCatching { cache.clearAll() }
        runSuspendCatching { library.clearCoverImages() }
        refreshCoverStats()
    }

    /** The library was synchronized: follow up on what that may have changed. */
    fun onLibrarySynced() {
        scope.launch {
            runSuspendCatching { reconcileRemovedFromServer() }
            smartPasses.trySend(Unit)
            if (settings.current.cache.syncCoverArt) syncCoverArt()
        }
    }

    // endregion

    // region Downloads

    /** Keeps [songs] on the device as downloads of the user. */
    fun download(songs: List<Song>) = request(collection = null) { songs }

    fun downloadAlbum(album: Album) = request(AudioCacheService.TYPE_ALBUM to album.id) {
        album.song?.takeIf { it.isNotEmpty() } ?: repository.albumSongs(album.id)
    }

    fun downloadPlaylist(playlist: Playlist) = request(AudioCacheService.TYPE_PLAYLIST to playlist.id) {
        playlist.entry?.takeIf { it.isNotEmpty() } ?: repository.playlistSongs(playlist.id)
    }

    fun downloadArtist(artist: Artist) = request(collection = null) { repository.artistSongs(artist.id) }

    /** Deletes the cached audio of [songIds] and stops their downloads. */
    fun removeDownloads(songIds: Collection<String>) {
        scope.launch { runSuspendCatching { cache.remove(songIds) } }
    }

    private fun request(collection: Pair<String, String>?, load: suspend () -> List<Song>) {
        scope.launch {
            val songs = runSuspendCatching { load() }.getOrDefault(emptyList()).distinctBy { it.id }
            if (songs.isEmpty()) {
                toaster.error(strings().t("toast.server.error"))
                return@launch
            }
            // The songs are listed offline from the library, so they have to be in it.
            runSuspendCatching { repository.remember(songs) }
            val owned = cache.cached.value
            val missing = songs.count { owned[it.id]?.source != AudioCacheSource.Explicit }
            for (song in songs) runSuspendCatching { cache.request(song.id, AudioCacheSource.Explicit) }
            if (collection != null) {
                runSuspendCatching { cache.recordCollection(collection.first, collection.second) }
            }
            when {
                missing == 0 -> toaster.info(strings().t("offline.badge.downloaded"))
                // Queued all the same: the downloads start once the server answers again.
                !network.online -> toaster.error(strings().t("offline.disconnected"))
                else -> toaster.info(strings().plural("settings.storage.sync.downloading", missing))
            }
        }
    }

    private fun onCacheEvent(event: AudioCacheEvent) {
        if (event !is AudioCacheEvent.Downloaded || event.audio.source == AudioCacheSource.Lru) return
        // A song kept on purpose brings its lyrics and its cover along.
        scope.launch {
            val songId = event.audio.songId
            runSuspendCatching { lyrics.structured(songId) }
            val song = runSuspendCatching { repository.localSong(songId) }.getOrNull() ?: return@launch
            val useAlbumCover = settings.current.useAlbumCoverForSongs
            val ids = if (useAlbumCover) listOf(song.albumId, song.coverArt) else listOf(song.coverArt, song.albumId)
            runSuspendCatching { artwork.cover(ids.filterNotNull()) }
        }
    }

    // endregion

    // region Smart downloads

    /**
     * Brings the smart downloads in line with the rules. Switching the rules
     * off lets go of what they kept; otherwise nothing is decided while the
     * server cannot be asked or the connection is metered.
     */
    private suspend fun syncSmartDownloads() {
        val rules = settings.current.cache.smartRules
        if (!rules.enabled) {
            cache.syncSmartDownloads(emptyMap())
            return
        }
        if (!network.online || network.isMetered.value) return

        val favorites = if (rules.favoriteSongs) library.getStarredSongIds() else emptyList()
        val playlistSongs = LinkedHashSet<String>()
        var playlistsKnown = true
        if (rules.favoritePlaylists) {
            for (playlistId in library.getStarredPlaylistIds()) {
                val songs = runSuspendCatching { repository.playlistSongs(playlistId) }.getOrNull()
                if (songs.isNullOrEmpty()) {
                    playlistsKnown = false
                } else {
                    runSuspendCatching { repository.remember(songs) }
                    songs.mapTo(playlistSongs) { it.id }
                }
            }
        }
        cache.syncSmartDownloads(
            SmartDownloads.wanted(favorites, playlistSongs, playlistsKnown, cache.cached.value.values),
        )
    }

    /** Marks the cached songs the library no longer lists; see [missingFromLibrary]. */
    private suspend fun reconcileRemovedFromServer() {
        val entries = cache.cached.value
        // Without a synced library every song would count as gone.
        if (entries.isEmpty() || library.countSongs() == 0) return
        val missing = missingFromLibrary(entries.values, library.getExistingSongIds(entries.keys)) ?: return
        cache.setRemovedFromServer(missing)
    }

    // endregion

    // region Images

    /** Downloads every image of the library that is not cached yet. */
    fun syncCoverArt() {
        if (coverSyncJob?.isActive == true) return
        // Shown as running from the moment it was asked for.
        _coverSync.value = CoverSyncProgress(0, 0)
        coverSyncJob = scope.launch {
            try {
                downloadCoverArt()
            } finally {
                // Also after a cancellation: what was fetched has to fit the quota.
                withContext(NonCancellable) { trimCovers() }
                _coverSync.value = null
            }
        }
    }

    fun cancelCoverSync() {
        coverSyncJob?.cancel()
    }

    private suspend fun downloadCoverArt() {
        val current = settings.current
        val ids = library.getCoverArtIds(
            songCovers = !current.useAlbumCoverForSongs,
            albumIds = current.useAlbumCoverForSongs,
        )
        if (ids.isEmpty()) return
        val quota = current.cache.assetsQuota
        val workers = current.cache.coverArtConcurrency.coerceIn(1, MAX_COVER_WORKERS)
        val processed = AtomicInteger(0)
        var size = library.getCoverCacheStats().sizeBytes
        _coverSync.value = CoverSyncProgress(0, ids.size)

        val queue = Channel<String>(Channel.UNLIMITED)
        ids.forEach { queue.trySend(it) }
        queue.close()
        coroutineScope {
            repeat(workers) {
                launch {
                    for (id in queue) {
                        // Past the quota every new image would push out an older one.
                        val full = quota > 0 && size >= quota
                        if (!full && network.online && library.getCoverImageSize(id) == null) {
                            val file = runSuspendCatching { artwork.cover(listOf(id)) }.getOrNull()
                            if (file != null) size += file.length()
                        }
                        _coverSync.value = CoverSyncProgress(processed.incrementAndGet(), ids.size)
                    }
                }
            }
        }
    }

    private suspend fun trimCovers() {
        runSuspendCatching { library.trimCoverImages(settings.current.cache.assetsQuota) }
        refreshCoverStats()
    }

    /** Counts the cached images again; they change without this class being told. */
    suspend fun refreshCoverStats() {
        runSuspendCatching { library.getCoverCacheStats() }.getOrNull()?.let {
            coverStats.value = PoolStats(it.count, it.sizeBytes)
        }
    }

    // endregion

    // region Storage settings

    suspend fun clearPool(source: AudioCacheSource) {
        runSuspendCatching { cache.clear(source) }
    }

    suspend fun clearCovers() {
        cancelCoverSync()
        runSuspendCatching { library.clearCoverImages() }
        refreshCoverStats()
    }

    /** Empties every pool, the cached lyrics included. */
    suspend fun clearAll() {
        cancelCoverSync()
        runSuspendCatching { cache.clearAll() }
        runSuspendCatching { library.clearCoverImages() }
        runSuspendCatching { library.clearLyrics() }
        runSuspendCatching { lyrics.clearCache() }
        refreshCoverStats()
    }

    /** Every entry of the cache index with a name to show, newest first. */
    suspend fun items(): List<CachedItem> {
        val rows = library.getCacheEntries()
        val audioIds = rows.filter { it.type == CachedItemType.Audio.id }.map { it.id }
        val albumIds = rows.filter { it.type == CachedItemType.Album.id }.map { it.id }
        val songs = audioIds.chunked(LOOKUP_CHUNK).flatMap { library.getSongsByIds(it) }.associateBy { it.id }
        val albums = albumIds.chunked(LOOKUP_CHUNK).flatMap { library.getAlbumsByIds(it) }.associateBy { it.id }
        val playlists = library.getPlaylists(LibraryPagination(limit = MAX_PLAYLISTS, offset = 0)).items
            .associateBy { it.id }
        val coverNames = if (rows.any { it.type == CachedItemType.Cover.id }) library.getCoverNames() else emptyMap()
        val audio = cache.cached.value

        return rows.mapNotNull { row ->
            val type = CachedItemType.of(row.type) ?: return@mapNotNull null
            var name = row.id
            var subtitle: String? = null
            when (type) {
                CachedItemType.Audio -> songs[row.id]?.let {
                    name = it.title.ifEmpty { row.id }
                    subtitle = it.artist?.takeIf(String::isNotEmpty)
                }
                CachedItemType.Album -> albums[row.id]?.let {
                    name = it.name.ifEmpty { row.id }
                    subtitle = it.artist.takeIf(String::isNotEmpty)
                }
                CachedItemType.Playlist -> playlists[row.id]?.let { name = it.name.ifEmpty { row.id } }
                CachedItemType.Cover -> coverNames[row.id]?.let { name = it }
            }
            CachedItem(
                key = row.key,
                id = row.id,
                type = type,
                source = AudioCacheSource.of(row.source).takeIf { type != CachedItemType.Cover },
                name = name,
                subtitle = subtitle,
                sizeBytes = row.sizeBytes,
                cachedAt = row.cachedAt,
                removedFromServer = audio[row.id]?.removedFromServer == true && type == CachedItemType.Audio,
            )
        }
    }

    /** Removes one entry of the cache index, and what it stands for. */
    suspend fun remove(item: CachedItem) {
        when (item.type) {
            CachedItemType.Audio -> cache.remove(listOf(item.id))
            CachedItemType.Cover -> {
                library.deleteCoverImage(item.id)
                refreshCoverStats()
            }
            CachedItemType.Album, CachedItemType.Playlist -> cache.forgetCollection(item.type.id, item.id)
        }
    }

    // endregion

    private fun pools(audio: Collection<CachedAudio>, covers: PoolStats): CachePools {
        fun pool(source: AudioCacheSource): PoolStats {
            val entries = audio.filter { it.source == source }
            return PoolStats(entries.size, entries.sumOf { it.sizeBytes })
        }
        return CachePools(
            explicit = pool(AudioCacheSource.Explicit),
            smart = pool(AudioCacheSource.Smart),
            lru = pool(AudioCacheSource.Lru),
            covers = covers,
        )
    }

    private companion object {
        const val SMART_PASS_DELAY_MS = 1_500L
        const val MAX_COVER_WORKERS = 8
        const val LOOKUP_CHUNK = 500
        const val MAX_PLAYLISTS = 10_000
    }
}
