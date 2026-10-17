package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.data.db.AonsokuDatabase
import github.realtvop.aonsoku.plugins.data.db.dao.CacheMetaDao
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity
import github.realtvop.aonsoku.plugins.debug.NativeLogger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File
import java.io.IOException

/** Why an audio file is kept on the device, which decides when it may go. */
enum class AudioCacheSource(
    val id: String,
    /** A request of a higher rank takes over a file kept for a lower one. */
    internal val rank: Int,
    /** Downloads of a higher priority start first. */
    internal val priority: Int,
) {
    /** The user asked for it. Only the user removes it. */
    Explicit("explicit", rank = 2, priority = 1),

    /** A smart-download rule matched it. Removed once no rule matches any more. */
    Smart("smart", rank = 1, priority = 0),

    /** Kept while listening. The least recently played go when the pool is over its quota. */
    Lru("lru", rank = 0, priority = 2),
    ;

    companion object {
        /** Rows written before sources existed count as the user's own downloads. */
        fun of(id: String?): AudioCacheSource = entries.firstOrNull { it.id == id } ?: Explicit
    }
}

/** An audio file kept on the device. */
data class CachedAudio(
    val songId: String,
    val source: AudioCacheSource,
    /** The smart-download rules that keep the file. */
    val triggers: List<String> = emptyList(),
    val sizeBytes: Long,
    val cachedAt: Long,
    val lastAccessedAt: Long,
    /** The library no longer lists the song; the file still plays. */
    val removedFromServer: Boolean = false,
)

/** A download that waits for its turn or runs. */
data class AudioDownload(
    val songId: String,
    val source: AudioCacheSource,
    val loaded: Long = 0,
    /** 0 while the size is not known. */
    val total: Long = 0,
    val started: Boolean = false,
) {
    /** How far the download is, when that can be told. */
    val fraction: Float?
        get() = if (started && total > 0) (loaded.toFloat() / total).coerceIn(0f, 1f) else null
}

sealed interface AudioCacheEvent {
    data class Downloaded(val audio: CachedAudio) : AudioCacheEvent

    /** [permanent] when asking again would end the same way. */
    data class Failed(
        val songId: String,
        val source: AudioCacheSource,
        val permanent: Boolean,
        val message: String,
    ) : AudioCacheEvent

    data class Removed(val songIds: Set<String>) : AudioCacheEvent
}

/**
 * Application-scoped owner of the audio kept for offline playback: the files
 * in the audio cache directories, the index that says why each one is kept
 * (rows of type `audio` in the `cacheMeta` table), and the queue of downloads
 * that fills them. Playback, the user's downloads, and smart downloads all go
 * through this one queue, so a song is never fetched twice at the same time.
 *
 * A download the user asked for survives the process: it is written down
 * until it has succeeded, and one that failed for a passing reason (no
 * network, a server that is restarting) runs again on the next [resume].
 */
class AudioCacheService internal constructor(
    private val index: CacheMetaDao,
    /** Where cached audio is looked for; new files go to the first. */
    private val directories: () -> List<File>,
    /** Where unfinished downloads are written. */
    private val tempDirectory: () -> File,
    /** Remembers the user's downloads that have not succeeded yet. */
    private val pendingFile: () -> File,
    private val fetch: suspend (songId: String, onProgress: (Long, Long) -> Unit) -> DownloadedAudio,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val now: () -> Long = System::currentTimeMillis,
    private val parallelDownloads: Int = MAX_PARALLEL_DOWNLOADS,
) {
    private enum class TaskState { Queued, Running, Stalled }

    private class Task(
        val songId: String,
        var source: AudioCacheSource,
        var triggers: List<String>,
        val order: Long,
    ) {
        var state = TaskState.Queued
        var job: Job? = null
    }

    private val mutex = Mutex()
    private var loaded = false
    private val tasks = LinkedHashMap<String, Task>()
    private var nextOrder = 0L
    private var lruQuota = 0L

    private val _cached = MutableStateFlow<Map<String, CachedAudio>>(emptyMap())
    private val _downloads = MutableStateFlow<Map<String, AudioDownload>>(emptyMap())
    private val _events = MutableSharedFlow<AudioCacheEvent>(extraBufferCapacity = 64)

    /** The cached audio by song id. Empty until [initialize] has run. */
    val cached: StateFlow<Map<String, CachedAudio>> = _cached.asStateFlow()

    /** The downloads that wait or run, by song id. */
    val downloads: StateFlow<Map<String, AudioDownload>> = _downloads.asStateFlow()

    val events: SharedFlow<AudioCacheEvent> = _events.asSharedFlow()

    /**
     * Loads the index and brings it in line with the files: a row without a
     * file goes, and a file without a row (left by an earlier version of the
     * app, which kept its index elsewhere) is adopted as a download of the
     * user, the one kind that is never removed behind their back. Downloads
     * that were still owed when the process ended are queued again.
     */
    suspend fun initialize() = locked { }

    /** Asks for [songId] to be kept; see [request]. */
    fun download(songId: String, source: AudioCacheSource, triggers: List<String> = emptyList()) {
        scope.launch {
            try {
                request(songId, source, triggers)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                NativeLogger.error("Cannot queue the download of $songId: ${error.message}", "audio-cache")
            }
        }
    }

    /**
     * Makes sure [songId] is kept for [source]. A file that is already there
     * is not fetched again; it changes hands when [source] outranks what it
     * was kept for (a song cached while listening becomes a download when the
     * user asks for it), and a smart download gets its [triggers] refreshed.
     */
    suspend fun request(songId: String, source: AudioCacheSource, triggers: List<String> = emptyList()) =
        locked {
            if (songId.isEmpty()) return@locked
            var existing = _cached.value[songId]
            if (existing != null && file(songId) == null) {
                // The file went missing behind the index; fetch it afresh.
                evict(listOf(songId))
                existing = null
            }
            if (existing != null) {
                val promoted = source.rank > existing.source.rank
                val retagged = source == AudioCacheSource.Smart &&
                    existing.source == AudioCacheSource.Smart && existing.triggers != triggers
                if (promoted || retagged || source == AudioCacheSource.Lru) {
                    store(
                        existing.copy(
                            source = if (promoted) source else existing.source,
                            triggers = when {
                                promoted || retagged -> triggers.takeIf { source == AudioCacheSource.Smart }.orEmpty()
                                else -> existing.triggers
                            },
                            lastAccessedAt = now(),
                        ),
                    )
                }
                return@locked
            }
            val pending = tasks[songId]
            if (pending != null) {
                if (source.rank > pending.source.rank) {
                    pending.source = source
                    pending.triggers = triggers
                    if (source == AudioCacheSource.Explicit) savePending()
                } else if (source == pending.source) {
                    pending.triggers = triggers
                }
                if (pending.state == TaskState.Stalled) pending.state = TaskState.Queued
                publish(pending)
            } else {
                val task = Task(songId, source, triggers, nextOrder++)
                tasks[songId] = task
                publish(task)
                if (source == AudioCacheSource.Explicit) savePending()
            }
            pump()
        }

    /** Stops waiting for, or fetching, [songIds]. What is cached stays. */
    suspend fun cancel(songIds: Collection<String>) = locked {
        if (drop(songIds.mapNotNull(tasks::get))) savePending()
        pump()
    }

    /** Stops the downloads asked for [source], or all of them. */
    suspend fun cancelAll(source: AudioCacheSource? = null) = locked {
        if (drop(tasks.values.filter { source == null || it.source == source })) savePending()
        pump()
    }

    /** Runs the downloads again that failed for a passing reason. */
    suspend fun resume() = locked {
        for (task in tasks.values) {
            if (task.state == TaskState.Stalled) {
                task.state = TaskState.Queued
                publish(task)
            }
        }
        pump()
    }

    /** Deletes the cached audio of [songIds], and stops their downloads. */
    suspend fun remove(songIds: Collection<String>) = locked {
        val pendingChanged = drop(songIds.mapNotNull(tasks::get))
        evict(songIds.filter { it in _cached.value })
        if (pendingChanged) savePending()
        pump()
    }

    /**
     * Empties one pool: the audio kept for [source] and its unfinished
     * downloads. With the user's downloads go the notes of which albums and
     * playlists were downloaded.
     */
    suspend fun clear(source: AudioCacheSource) = locked {
        val pendingChanged = drop(tasks.values.filter { it.source == source })
        evict(_cached.value.values.filter { it.source == source }.map { it.songId })
        if (source == AudioCacheSource.Explicit) {
            COLLECTION_TYPES.forEach { index.deleteByType(it) }
        }
        if (pendingChanged) savePending()
        pump()
    }

    /** Deletes every cached audio file, indexed or not, and stops every download. */
    suspend fun clearAll() = locked {
        drop(tasks.values.toList())
        val removed = _cached.value.keys
        for (directory in directories()) {
            directory.listFiles()?.forEach { file ->
                if (file.isFile && file.name != PENDING_FILE_NAME) file.delete()
            }
        }
        index.deleteByType(TYPE_AUDIO)
        COLLECTION_TYPES.forEach { index.deleteByType(it) }
        _cached.value = emptyMap()
        savePending()
        if (removed.isNotEmpty()) _events.tryEmit(AudioCacheEvent.Removed(removed))
    }

    /** Notes that [songId] was played from its file, which keeps it from being the next to go. */
    suspend fun touch(songId: String) = locked {
        val existing = _cached.value[songId] ?: return@locked
        val time = now()
        // Playing a song reports more than once; one write a minute is plenty.
        if (time - existing.lastAccessedAt < TOUCH_INTERVAL_MS) return@locked
        _cached.update { it + (songId to existing.copy(lastAccessedAt = time)) }
        index.touch(key(songId), time)
    }

    /**
     * Sets how many bytes the audio kept while listening may take (0 for no
     * limit) and removes the least recently played until it fits.
     */
    suspend fun setLruQuota(bytes: Long) = locked {
        lruQuota = bytes.coerceAtLeast(0)
        enforceQuota()
    }

    /**
     * Brings the smart downloads in line with [wanted], the songs the rules
     * match with the rules that match them: fetches the missing, refreshes
     * the triggers, takes over what was only kept while listening, and
     * removes the smart downloads no rule matches any more. The user's own
     * downloads are left alone.
     */
    suspend fun syncSmartDownloads(wanted: Map<String, List<String>>) {
        val stale = locked {
            drop(tasks.values.filter { it.source == AudioCacheSource.Smart && it.songId !in wanted })
            pump()
            _cached.value.values
                .filter { it.source == AudioCacheSource.Smart && it.songId !in wanted }
                .map { it.songId }
        }
        if (stale.isNotEmpty()) remove(stale)
        for ((songId, triggers) in wanted) request(songId, AudioCacheSource.Smart, triggers)
    }

    /**
     * Marks the cached songs in [missing] as gone from the library and
     * clears the mark of all others. The files stay playable either way.
     */
    suspend fun setRemovedFromServer(missing: Set<String>) = locked {
        val changed = _cached.value.values
            .filter { it.removedFromServer != (it.songId in missing) }
            .map { it.copy(removedFromServer = it.songId in missing) }
        if (changed.isEmpty()) return@locked
        index.bulkUpsert(changed.map(::row))
        _cached.update { all -> all + changed.associateBy { it.songId } }
    }

    /** Notes that the album or playlist [id] was downloaded as a whole. */
    suspend fun recordCollection(type: String, id: String) = locked {
        require(type in COLLECTION_TYPES) { "Unknown collection type $type" }
        val time = now()
        index.upsert(
            CacheMetaEntity(
                key = "$type:$id",
                id = id,
                type = type,
                source = AudioCacheSource.Explicit.id,
                sizeBytes = 0,
                cachedAt = time,
                lastAccessedAt = time,
            ),
        )
    }

    /** Drops the note that the album or playlist [id] was downloaded; its songs stay. */
    suspend fun forgetCollection(type: String, id: String) = locked {
        require(type in COLLECTION_TYPES) { "Unknown collection type $type" }
        index.delete("$type:$id")
    }

    /** The cached file of [songId], if there is one. */
    fun file(songId: String): File? = AudioCacheUtils.findFile(directories(), songId)

    // region Queue

    /** Starts as many waiting downloads as there are free places; call with the lock held. */
    private fun pump() {
        while (tasks.values.count { it.state == TaskState.Running } < parallelDownloads) {
            val next = tasks.values
                .filter { it.state == TaskState.Queued }
                .maxWithOrNull(compareBy<Task> { it.source.priority }.thenByDescending { it.order })
                ?: return
            next.state = TaskState.Running
            publish(next)
            next.job = scope.launch { run(next) }
        }
    }

    private suspend fun run(task: Task) {
        val result = try {
            Result.success(
                fetch(task.songId) { loaded, total ->
                    _downloads.update { all ->
                        val current = all[task.songId] ?: return@update all
                        all + (task.songId to current.copy(loaded = loaded, total = total, started = true))
                    }
                },
            )
        } catch (cancelled: CancellationException) {
            if (currentCoroutineContext().isActive) {
                // Not this download being called off: something inside it gave up.
                Result.failure(IOException("The download was interrupted", cancelled))
            } else {
                // Whoever cancelled the task has taken it off the queue already.
                // The transfer may have put its file in place a moment before.
                withContext(NonCancellable) { mutex.withLock { discardUnowned(task.songId) } }
                throw cancelled
            }
        } catch (error: Exception) {
            Result.failure(error)
        }
        // Finishing is not interrupted half-way: the file and its row belong together.
        withContext(NonCancellable) {
            mutex.withLock {
                try {
                    finish(task, result)
                } catch (error: Exception) {
                    NativeLogger.error("Cannot record the download of ${task.songId}: ${error.message}", "audio-cache")
                    if (tasks[task.songId] === task) {
                        tasks.remove(task.songId)
                        _downloads.update { it - task.songId }
                    }
                }
                pump()
            }
        }
    }

    private suspend fun finish(task: Task, result: Result<DownloadedAudio>) {
        if (tasks[task.songId] !== task) {
            // Dropped while the lock was awaited.
            if (result.isSuccess) discardUnowned(task.songId)
            return
        }
        result.fold(
            onSuccess = { audio -> completed(task, audio) },
            onFailure = { error -> failed(task, error) },
        )
    }

    private suspend fun completed(task: Task, audio: DownloadedAudio) {
        tasks.remove(task.songId)
        _downloads.update { it - task.songId }
        val time = now()
        val entry = CachedAudio(
            songId = task.songId,
            source = task.source,
            triggers = task.triggers.takeIf { task.source == AudioCacheSource.Smart }.orEmpty(),
            sizeBytes = audio.sizeBytes,
            cachedAt = time,
            lastAccessedAt = time,
        )
        store(entry)
        if (task.source == AudioCacheSource.Explicit) savePending()
        _events.tryEmit(AudioCacheEvent.Downloaded(entry))
        if (task.source == AudioCacheSource.Lru) enforceQuota()
    }

    private fun failed(task: Task, error: Throwable) {
        val permanent = error is AudioUnavailableException
        NativeLogger.warn(
            "Download of ${task.songId} failed${if (permanent) " for good" else ""}: ${error.message}",
            "audio-cache",
        )
        // Only what the user asked for is owed; the rest is asked for again when it matters.
        if (!permanent && task.source == AudioCacheSource.Explicit) {
            task.state = TaskState.Stalled
            task.job = null
            _downloads.update { it - task.songId }
        } else {
            tasks.remove(task.songId)
            _downloads.update { it - task.songId }
            if (task.source == AudioCacheSource.Explicit) savePending()
        }
        _events.tryEmit(
            AudioCacheEvent.Failed(task.songId, task.source, permanent, error.message ?: error.toString()),
        )
    }

    /**
     * Deletes what a dropped download wrote. A newer request for the song
     * owns the file by now; without one, what was written is unwanted. Call
     * with the lock held.
     */
    private fun discardUnowned(songId: String) {
        if (songId !in tasks && songId !in _cached.value) {
            AudioCacheUtils.deleteFiles(directories(), songId)
        }
    }

    /** Takes [dropped] off the queue; true when what is owed to the user changed. */
    private fun drop(dropped: List<Task>): Boolean {
        if (dropped.isEmpty()) return false
        for (task in dropped) {
            tasks.remove(task.songId)
            task.job?.cancel()
        }
        val ids = dropped.map { it.songId }.toSet()
        _downloads.update { it - ids }
        return dropped.any { it.source == AudioCacheSource.Explicit }
    }

    /** Shows [task] among the downloads while it waits or runs. */
    private fun publish(task: Task) {
        if (task.state == TaskState.Stalled) return
        _downloads.update { all ->
            val current = all[task.songId]
            all + (
                task.songId to (current?.copy(source = task.source) ?: AudioDownload(task.songId, task.source))
                )
        }
    }

    private fun savePending() {
        val owed = tasks.values.filter { it.source == AudioCacheSource.Explicit }
        val file = pendingFile()
        try {
            if (owed.isEmpty()) {
                file.delete()
                return
            }
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(JSONArray(owed.map { it.songId }).toString(), Charsets.UTF_8)
            if (!temp.renameTo(file)) {
                temp.copyTo(file, overwrite = true)
                temp.delete()
            }
        } catch (error: Exception) {
            NativeLogger.warn("Cannot write the pending downloads: ${error.message}", "audio-cache")
        }
    }

    private fun loadPending(): List<String> = try {
        val file = pendingFile()
        if (!file.exists()) {
            emptyList()
        } else {
            val array = JSONArray(file.readText(Charsets.UTF_8))
            (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
        }
    } catch (error: Exception) {
        NativeLogger.warn("Cannot read the pending downloads: ${error.message}", "audio-cache")
        emptyList()
    }

    // endregion

    // region Index

    private suspend fun store(entry: CachedAudio) {
        index.upsert(row(entry))
        _cached.update { it + (entry.songId to entry) }
    }

    /** Deletes the files and rows of [songIds]; call with the lock held. */
    private suspend fun evict(songIds: List<String>) {
        if (songIds.isEmpty()) return
        val folders = directories()
        for (songId in songIds) AudioCacheUtils.deleteFiles(folders, songId)
        songIds.map(::key).chunked(SQL_VARIABLE_CHUNK).forEach { index.deleteKeys(it) }
        val removed = songIds.toSet()
        _cached.update { it - removed }
        _events.tryEmit(AudioCacheEvent.Removed(removed))
    }

    private suspend fun enforceQuota() {
        evict(lruEvictionPlan(_cached.value.values, lruQuota))
    }

    private suspend fun load() {
        val folders = directories()
        val files = LinkedHashMap<String, File>()
        for (directory in folders) {
            directory.listFiles()?.forEach { file ->
                if (!file.isFile || file.extension !in AudioCacheUtils.AUDIO_EXTENSIONS) return@forEach
                val songId = AudioCacheUtils.songId(file.nameWithoutExtension) ?: return@forEach
                files.putIfAbsent(songId, file)
            }
        }
        val rows = index.getByTypeOldestFirst(TYPE_AUDIO)
        val lost = rows.filter { it.id !in files }
        lost.map { it.key }.chunked(SQL_VARIABLE_CHUNK).forEach { index.deleteKeys(it) }

        val entries = LinkedHashMap<String, CachedAudio>()
        for (row in rows) {
            if (row.id in files) entries[row.id] = entry(row)
        }
        val adopted = files.filterKeys { it !in entries }.map { (songId, file) ->
            val written = file.lastModified().takeIf { it > 0 } ?: now()
            CachedAudio(
                songId = songId,
                source = AudioCacheSource.Explicit,
                sizeBytes = file.length(),
                cachedAt = written,
                lastAccessedAt = written,
            )
        }
        if (adopted.isNotEmpty()) {
            NativeLogger.info("Adopted ${adopted.size} audio files that had no index entry", "audio-cache")
            adopted.map(::row).chunked(SQL_VARIABLE_CHUNK).forEach { index.bulkUpsert(it) }
            adopted.forEach { entries[it.songId] = it }
        }
        _cached.value = entries

        // What an interrupted download left behind.
        tempDirectory().listFiles()?.forEach { file ->
            val name = file.name
            if (name.startsWith(NativeDownloadManager.TEMP_PREFIX) && name.endsWith(NativeDownloadManager.TEMP_SUFFIX)) {
                file.delete()
            }
        }

        for (songId in loadPending()) {
            if (songId in entries || songId in tasks) continue
            val task = Task(songId, AudioCacheSource.Explicit, emptyList(), nextOrder++)
            tasks[songId] = task
            publish(task)
        }
        pump()
    }

    private fun entry(row: CacheMetaEntity) = CachedAudio(
        songId = row.id,
        source = AudioCacheSource.of(row.source),
        triggers = row.triggersJson?.let(::parseTriggers).orEmpty(),
        sizeBytes = row.sizeBytes,
        cachedAt = row.cachedAt,
        lastAccessedAt = row.lastAccessedAt,
        removedFromServer = row.removedFromServer == true,
    )

    private fun row(entry: CachedAudio) = CacheMetaEntity(
        key = key(entry.songId),
        id = entry.songId,
        type = TYPE_AUDIO,
        source = entry.source.id,
        triggersJson = entry.triggers.takeIf { it.isNotEmpty() }?.let { JSONArray(it).toString() },
        sizeBytes = entry.sizeBytes,
        cachedAt = entry.cachedAt,
        lastAccessedAt = entry.lastAccessedAt,
        removedFromServer = entry.removedFromServer.takeIf { it },
    )

    private fun parseTriggers(json: String): List<String> = try {
        val array = JSONArray(json)
        (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
    } catch (_: Exception) {
        emptyList()
    }

    // endregion

    /** Runs [block] alone, off the caller's thread, on a loaded index. */
    private suspend fun <T> locked(block: suspend () -> T): T = withContext(io) {
        mutex.withLock {
            if (!loaded) {
                load()
                loaded = true
            }
            block()
        }
    }

    companion object {
        const val TYPE_AUDIO = "audio"
        const val TYPE_ALBUM = "album"
        const val TYPE_PLAYLIST = "playlist"
        private val COLLECTION_TYPES = listOf(TYPE_ALBUM, TYPE_PLAYLIST)

        /** As many as the download queue of the web app runs. */
        private const val MAX_PARALLEL_DOWNLOADS = 4
        private const val TOUCH_INTERVAL_MS = 60_000L

        /** SQLite binds at most 999 variables per statement on older devices. */
        private const val SQL_VARIABLE_CHUNK = 500
        private const val PENDING_FILE_NAME = "pending-downloads.json"

        fun key(songId: String): String = "audio:$songId"

        /**
         * The songs to remove so that the audio kept while listening fits in
         * [quota] bytes: the least recently played first. A quota of 0 means
         * no limit, and downloads of the user or of a rule never count.
         */
        fun lruEvictionPlan(entries: Collection<CachedAudio>, quota: Long): List<String> {
            if (quota <= 0) return emptyList()
            val pool = entries.filter { it.source == AudioCacheSource.Lru }.sortedBy { it.lastAccessedAt }
            var size = pool.sumOf { it.sizeBytes }
            val plan = ArrayList<String>()
            for (entry in pool) {
                if (size <= quota) break
                plan += entry.songId
                size -= entry.sizeBytes
            }
            return plan
        }

        @Volatile
        private var instance: AudioCacheService? = null

        fun getInstance(context: Context): AudioCacheService = instance ?: synchronized(this) {
            instance ?: create(context.applicationContext).also { instance = it }
        }

        private fun create(context: Context): AudioCacheService {
            val downloader = NativeDownloadManager(context, AuthenticationService.getInstance(context))
            return AudioCacheService(
                index = AonsokuDatabase.getInstance(context).cacheMetaDao(),
                directories = {
                    listOf(
                        AudioCacheUtils.getCacheDirectory(context, createIfNeeded = true),
                        AudioCacheUtils.getSecondaryCacheDirectory(context),
                    )
                },
                tempDirectory = { context.cacheDir },
                pendingFile = {
                    File(AudioCacheUtils.getCacheDirectory(context, createIfNeeded = true), PENDING_FILE_NAME)
                },
                fetch = { songId, onProgress -> downloader.fetch(songId, onProgress = onProgress) },
                scope = CoroutineScope(
                    SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, error ->
                        NativeLogger.error("Audio cache failure: ${error.message}", "audio-cache")
                    },
                ),
            )
        }
    }
}
