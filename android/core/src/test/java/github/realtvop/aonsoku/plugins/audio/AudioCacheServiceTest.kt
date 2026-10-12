package github.realtvop.aonsoku.plugins.audio

import android.util.Log
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.mockito.MockedStatic
import org.mockito.Mockito
import java.io.File
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class AudioCacheServiceTest {
    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var mockedLog: MockedStatic<Log>
    private lateinit var primary: File
    private lateinit var secondary: File
    private lateinit var temp: File
    private lateinit var pending: File

    private val index = FakeCacheMetaDao()
    private val fetcher = FakeFetcher()
    private var clock = 1_000L

    @Before
    fun setUp() {
        // The service logs through android.util.Log, which the JVM does not have.
        mockedLog = Mockito.mockStatic(Log::class.java)
        primary = folder.newFolder("files", "AudioCache")
        secondary = folder.newFolder("cache", "AudioCache")
        temp = folder.newFolder("temp")
        pending = File(primary, "pending-downloads.json")
    }

    @After
    fun tearDown() {
        mockedLog.close()
    }

    @Test
    fun aDownloadIsIndexedUnderWhatItWasAskedFor() = cacheTest { cache ->
        val events = collectEvents(cache)

        cache.request("a", AudioCacheSource.Explicit)

        val audio = cache.cached.value.getValue("a")
        assertEquals(AudioCacheSource.Explicit, audio.source)
        assertEquals(FakeFetcher.DEFAULT_SIZE, audio.sizeBytes)
        assertEquals(audioFile("a"), cache.file("a"))
        val row = index.rows.getValue("audio:a")
        assertEquals(listOf("a", "audio", "explicit"), listOf(row.id, row.type, row.source))
        assertTrue(cache.downloads.value.isEmpty())
        assertEquals(listOf<AudioCacheEvent>(AudioCacheEvent.Downloaded(audio)), events)
        assertFalse(pending.exists())
    }

    @Test
    fun fourDownloadsRunAtATimeAndPlaybackGoesFirst() = cacheTest { cache ->
        val gates = listOf("s1", "s2", "s3", "s4", "s5", "e1", "l1").associateWith { fetcher.hold(it) }
        for (songId in listOf("s1", "s2", "s3", "s4", "s5")) cache.request(songId, AudioCacheSource.Smart)
        cache.request("e1", AudioCacheSource.Explicit)
        cache.request("l1", AudioCacheSource.Lru)

        // The first four took the free places; the rest waits.
        assertEquals(listOf("s1", "s2", "s3", "s4"), fetcher.calls)
        assertEquals(7, cache.downloads.value.size)

        // A free place goes to what plays now, then to the user, then to the rules.
        gates.getValue("s1").complete(Unit)
        gates.getValue("s2").complete(Unit)
        gates.getValue("s3").complete(Unit)
        assertEquals(listOf("s1", "s2", "s3", "s4", "l1", "e1", "s5"), fetcher.calls)
    }

    @Test
    fun aSongThatIsAlreadyOnItsWayIsNotFetchedTwice() = cacheTest { cache ->
        val gate = fetcher.hold("a")
        cache.request("a", AudioCacheSource.Lru)
        cache.request("a", AudioCacheSource.Lru)
        // The user asking for it meanwhile decides what the file is kept for.
        cache.request("a", AudioCacheSource.Explicit)
        assertEquals(AudioCacheSource.Explicit, cache.downloads.value.getValue("a").source)
        assertEquals(listOf("a"), pendingIds())

        gate.complete(Unit)

        assertEquals(listOf("a"), fetcher.calls)
        assertEquals(AudioCacheSource.Explicit, cache.cached.value.getValue("a").source)
        assertFalse(pending.exists())
    }

    @Test
    fun progressIsReportedWhileADownloadRuns() = cacheTest { cache ->
        val gate = fetcher.hold("a", reportBefore = 30L to 120L)
        cache.request("a", AudioCacheSource.Explicit)

        val download = cache.downloads.value.getValue("a")
        assertEquals(0.25f, download.fraction)
        gate.complete(Unit)
        assertTrue(cache.downloads.value.isEmpty())
    }

    @Test
    fun aSongKeptWhileListeningBecomesADownloadWhenAskedFor() = cacheTest { cache ->
        cache.request("a", AudioCacheSource.Lru)
        assertEquals(AudioCacheSource.Lru, cache.cached.value.getValue("a").source)

        cache.request("a", AudioCacheSource.Smart, listOf("favorite"))
        assertEquals(AudioCacheSource.Smart, cache.cached.value.getValue("a").source)
        assertEquals(listOf("favorite"), cache.cached.value.getValue("a").triggers)

        cache.request("a", AudioCacheSource.Explicit)
        assertEquals(AudioCacheSource.Explicit, cache.cached.value.getValue("a").source)
        assertTrue(cache.cached.value.getValue("a").triggers.isEmpty())

        // Nothing takes a download away from the user again.
        cache.request("a", AudioCacheSource.Smart, listOf("favorite"))
        cache.request("a", AudioCacheSource.Lru)
        assertEquals(AudioCacheSource.Explicit, cache.cached.value.getValue("a").source)
        assertEquals("explicit", index.rows.getValue("audio:a").source)
        assertEquals(listOf("a"), fetcher.calls)
    }

    @Test
    fun smartDownloadsFollowTheRules() = cacheTest { cache ->
        cache.request("listened", AudioCacheSource.Lru)
        cache.request("favorite", AudioCacheSource.Smart, listOf("favorite"))
        cache.request("dropped", AudioCacheSource.Smart, listOf("playlist"))
        cache.request("mine", AudioCacheSource.Explicit)
        val waiting = fetcher.hold("waiting")
        cache.request("waiting", AudioCacheSource.Smart, listOf("playlist"))

        cache.syncSmartDownloads(
            mapOf(
                "favorite" to listOf("favorite", "playlist"),
                "listened" to listOf("favorite"),
                "mine" to listOf("playlist"),
                "new" to listOf("favorite"),
            ),
        )
        waiting.complete(Unit)

        val cached = cache.cached.value
        assertEquals(setOf("listened", "favorite", "mine", "new"), cached.keys)
        assertEquals(listOf("favorite", "playlist"), cached.getValue("favorite").triggers)
        assertEquals(AudioCacheSource.Smart, cached.getValue("listened").source)
        assertEquals(listOf("favorite"), cached.getValue("listened").triggers)
        assertEquals(AudioCacheSource.Explicit, cached.getValue("mine").source)
        assertEquals(AudioCacheSource.Smart, cached.getValue("new").source)
        // What no rule matches any more is gone, also when it was still on its way.
        assertNull(cache.file("dropped"))
        assertNull(cache.file("waiting"))
        assertEquals("""["favorite","playlist"]""", index.rows.getValue("audio:favorite").triggersJson)
    }

    @Test
    fun theLeastRecentlyPlayedGoWhenTheQuotaIsExceeded() = cacheTest { cache ->
        fetcher.sizes += mapOf("a" to 100L, "b" to 100L, "c" to 100L, "d" to 100L, "mine" to 1_000L)
        cache.request("mine", AudioCacheSource.Explicit)
        for (songId in listOf("a", "b", "c")) {
            clock += 1_000
            cache.request(songId, AudioCacheSource.Lru)
        }

        cache.setLruQuota(250)
        assertEquals(setOf("mine", "b", "c"), cache.cached.value.keys)
        assertNull(cache.file("a"))

        // Playing a song keeps it from being the next to go.
        clock += 120_000
        cache.touch("b")
        clock += 1_000
        cache.request("d", AudioCacheSource.Lru)
        assertEquals(setOf("mine", "b", "d"), cache.cached.value.keys)

        cache.setLruQuota(0)
        cache.request("a", AudioCacheSource.Lru)
        assertEquals(setOf("mine", "a", "b", "d"), cache.cached.value.keys)
    }

    @Test
    fun onlyAudioKeptWhileListeningCountsAgainstTheQuota() {
        fun audio(id: String, source: AudioCacheSource, size: Long, playedAt: Long) =
            CachedAudio(id, source, sizeBytes = size, cachedAt = 0, lastAccessedAt = playedAt)
        val entries = listOf(
            audio("old", AudioCacheSource.Lru, 40, 1),
            audio("mine", AudioCacheSource.Explicit, 500, 0),
            audio("rule", AudioCacheSource.Smart, 500, 0),
            audio("older", AudioCacheSource.Lru, 40, 0),
            audio("new", AudioCacheSource.Lru, 40, 2),
        )

        assertEquals(emptyList<String>(), AudioCacheService.lruEvictionPlan(entries, 0))
        assertEquals(emptyList<String>(), AudioCacheService.lruEvictionPlan(entries, 120))
        assertEquals(listOf("older"), AudioCacheService.lruEvictionPlan(entries, 119))
        assertEquals(listOf("older", "old", "new"), AudioCacheService.lruEvictionPlan(entries, 1))
    }

    @Test
    fun theIndexIsBroughtInLineWithTheFiles() = runTest(UnconfinedTestDispatcher()) {
        index.upsert(row("gone", "explicit"))
        index.upsert(row("kept", "smart", triggers = """["favorite"]"""))
        index.upsert(CacheMetaEntity("cover:c1", "c1", "cover", "explicit", sizeBytes = 5, cachedAt = 1, lastAccessedAt = 1))
        writeAudio(primary, "kept", 10)
        // Files of the web app: it kept its index where the native app cannot read it.
        writeAudio(primary, "orphan", 20, extension = "flac")
        writeAudio(secondary, "elsewhere", 30)
        File(primary, "${AudioCacheUtils.cacheId("orphan")}.json").writeText("{}")
        File(primary, "notes.txt").writeText("not ours")
        val leftover = File(temp, "download_123.tmp").apply { writeText("half a song") }
        val unrelated = File(temp, "other.tmp").apply { writeText("someone else's") }

        val cache = service(this)
        cache.initialize()

        val cached = cache.cached.value
        assertEquals(setOf("kept", "orphan", "elsewhere"), cached.keys)
        assertEquals(AudioCacheSource.Smart, cached.getValue("kept").source)
        assertEquals(listOf("favorite"), cached.getValue("kept").triggers)
        assertEquals(AudioCacheSource.Explicit, cached.getValue("orphan").source)
        assertEquals(20L, cached.getValue("orphan").sizeBytes)
        assertEquals(setOf("audio:kept", "audio:orphan", "audio:elsewhere", "cover:c1"), index.rows.keys)
        assertFalse(leftover.exists())
        assertTrue(unrelated.exists())
        assertTrue(File(primary, "notes.txt").exists())
    }

    @Test
    fun aDownloadTheUserAskedForIsOwedUntilItSucceeds() = cacheTest { cache ->
        val events = collectEvents(cache)
        fetcher.failures["a"] = IOException("no route to host")

        cache.request("a", AudioCacheSource.Explicit)

        assertTrue(cache.cached.value.isEmpty())
        assertTrue(cache.downloads.value.isEmpty())
        assertEquals(listOf("a"), pendingIds())
        assertEquals(
            listOf<AudioCacheEvent>(
                AudioCacheEvent.Failed("a", AudioCacheSource.Explicit, permanent = false, message = "no route to host"),
            ),
            events,
        )

        // Still no network: asking again changes nothing.
        cache.resume()
        assertEquals(listOf("a"), pendingIds())

        fetcher.failures.clear()
        cache.resume()
        assertEquals(setOf("a"), cache.cached.value.keys)
        assertFalse(pending.exists())
        assertEquals(listOf("a", "a", "a"), fetcher.calls)
    }

    @Test
    fun whatIsOwedSurvivesTheProcess() = runTest(UnconfinedTestDispatcher()) {
        val gate = fetcher.hold("a")
        val first = service(this)
        first.request("a", AudioCacheSource.Explicit)
        first.request("b", AudioCacheSource.Smart)
        assertEquals(listOf("a"), pendingIds())

        // The process ends here; the next one starts over from what was written down.
        fetcher.calls.clear()
        fetcher.release("a")
        val second = service(this)
        second.initialize()

        assertEquals(listOf("a"), fetcher.calls)
        assertEquals(AudioCacheSource.Explicit, second.cached.value.getValue("a").source)
        assertFalse(pending.exists())
        gate.complete(Unit)
    }

    @Test
    fun aRefusalIsNotAskedForAgain() = cacheTest { cache ->
        val events = collectEvents(cache)
        fetcher.failures["a"] = AudioUnavailableException("Server returned HTTP 404")

        cache.request("a", AudioCacheSource.Explicit)
        assertFalse(pending.exists())
        assertTrue((events.single() as AudioCacheEvent.Failed).permanent)

        fetcher.failures.clear()
        cache.resume()
        assertEquals(listOf("a"), fetcher.calls)
        assertTrue(cache.cached.value.isEmpty())
    }

    @Test
    fun aDownloadNobodyAskedForIsForgottenWhenItFails() = cacheTest { cache ->
        fetcher.failures["rule"] = IOException("timeout")
        fetcher.failures["listened"] = IOException("timeout")
        cache.request("rule", AudioCacheSource.Smart, listOf("favorite"))
        cache.request("listened", AudioCacheSource.Lru)

        fetcher.failures.clear()
        cache.resume()

        assertEquals(listOf("rule", "listened"), fetcher.calls)
        assertTrue(cache.cached.value.isEmpty())
        assertFalse(pending.exists())
    }

    @Test
    fun removingASongStopsItsDownloadAndDeletesItsFile() = cacheTest { cache ->
        val events = collectEvents(cache)
        cache.request("kept", AudioCacheSource.Explicit)
        fetcher.hold("coming")
        cache.request("coming", AudioCacheSource.Explicit)
        events.clear()

        cache.remove(listOf("kept", "coming", "unknown"))

        assertTrue(cache.cached.value.isEmpty())
        assertTrue(cache.downloads.value.isEmpty())
        assertNull(cache.file("kept"))
        assertFalse(File(primary, "${AudioCacheUtils.cacheId("kept")}.json").exists())
        assertTrue(index.rows.isEmpty())
        assertFalse(pending.exists())
        assertEquals(listOf("coming"), fetcher.cancelled)
        assertEquals(listOf<AudioCacheEvent>(AudioCacheEvent.Removed(setOf("kept"))), events)
    }

    @Test
    fun cancellingADownloadKeepsWhatIsCached() = cacheTest { cache ->
        cache.request("kept", AudioCacheSource.Explicit)
        fetcher.hold("coming")
        fetcher.hold("later")
        cache.request("coming", AudioCacheSource.Explicit)
        cache.request("later", AudioCacheSource.Smart)

        cache.cancel(listOf("kept", "coming"))
        assertEquals(setOf("kept"), cache.cached.value.keys)
        assertEquals(setOf("later"), cache.downloads.value.keys)

        cache.cancelAll()
        assertTrue(cache.downloads.value.isEmpty())
        assertEquals(listOf("coming", "later"), fetcher.cancelled)
    }

    @Test
    fun clearingAPoolLeavesTheOthers() = cacheTest { cache ->
        cache.request("mine", AudioCacheSource.Explicit)
        cache.request("rule", AudioCacheSource.Smart, listOf("favorite"))
        cache.request("listened", AudioCacheSource.Lru)
        cache.recordCollection(AudioCacheService.TYPE_ALBUM, "album-1")
        cache.recordCollection(AudioCacheService.TYPE_PLAYLIST, "playlist-1")
        assertEquals("album", index.rows.getValue("album:album-1").type)

        cache.clear(AudioCacheSource.Lru)
        assertEquals(setOf("mine", "rule"), cache.cached.value.keys)
        assertTrue("album:album-1" in index.rows)

        // The notes of downloaded albums and playlists go with the downloads.
        cache.clear(AudioCacheSource.Explicit)
        assertEquals(setOf("rule"), cache.cached.value.keys)
        assertEquals(setOf("audio:rule"), index.rows.keys)
        assertNull(cache.file("mine"))
    }

    @Test
    fun clearingEverythingAlsoDeletesFilesTheIndexDoesNotKnow() = cacheTest { cache ->
        index.upsert(CacheMetaEntity("cover:c1", "c1", "cover", "explicit", sizeBytes = 5, cachedAt = 1, lastAccessedAt = 1))
        cache.request("mine", AudioCacheSource.Explicit)
        cache.recordCollection(AudioCacheService.TYPE_ALBUM, "album-1")
        fetcher.hold("coming")
        cache.request("coming", AudioCacheSource.Explicit)
        val stray = File(primary, "stray.audio").apply { writeText("?") }

        cache.clearAll()

        assertTrue(cache.cached.value.isEmpty())
        assertTrue(cache.downloads.value.isEmpty())
        assertFalse(stray.exists())
        assertEquals(emptyList<File>(), primary.listFiles().orEmpty().toList())
        // The images are another pool with its own owner.
        assertEquals(setOf("cover:c1"), index.rows.keys)
    }

    @Test
    fun songsThatLeftTheLibraryAreMarkedAndUnmarked() = cacheTest { cache ->
        cache.request("a", AudioCacheSource.Explicit)
        cache.request("b", AudioCacheSource.Explicit)

        cache.setRemovedFromServer(setOf("a"))
        assertTrue(cache.cached.value.getValue("a").removedFromServer)
        assertFalse(cache.cached.value.getValue("b").removedFromServer)
        assertEquals(true, index.rows.getValue("audio:a").removedFromServer)

        cache.setRemovedFromServer(emptySet())
        assertFalse(cache.cached.value.getValue("a").removedFromServer)
        assertNull(index.rows.getValue("audio:a").removedFromServer)
        // The file plays either way.
        assertEquals(audioFile("a"), cache.file("a"))
    }

    @Test
    fun aFileThatWentMissingIsFetchedAgain() = cacheTest { cache ->
        cache.request("a", AudioCacheSource.Lru)
        audioFile("a").delete()

        cache.request("a", AudioCacheSource.Lru)

        assertEquals(listOf("a", "a"), fetcher.calls)
        assertTrue(audioFile("a").exists())
        assertEquals(setOf("a"), cache.cached.value.keys)
    }

    @Test
    fun aDownloadCalledOffAsItsFileLandedLeavesNothingBehind() = cacheTest { cache ->
        fetcher.hold("a")
        fetcher.early += "a"
        cache.request("a", AudioCacheSource.Explicit)
        assertTrue(audioFile("a").exists())

        cache.remove(listOf("a"))

        assertEquals(listOf("a"), fetcher.cancelled)
        assertFalse(audioFile("a").exists())
        assertFalse(AudioCacheUtils.metadataFile(primary, "a").exists())
        assertTrue(cache.cached.value.isEmpty())
        assertTrue(cache.downloads.value.isEmpty())
        assertFalse(pending.exists())
    }

    @Test
    fun aDownloadThatGivesUpOnItsOwnIsAFailureAndNotAHangingPlace() = cacheTest { cache ->
        val events = collectEvents(cache)
        fetcher.failures["a"] = kotlinx.coroutines.CancellationException("timed out inside")
        cache.request("a", AudioCacheSource.Lru)

        // The place is free again and the song can be asked for anew.
        assertTrue(cache.downloads.value.isEmpty())
        assertEquals(1, events.filterIsInstance<AudioCacheEvent.Failed>().size)
        fetcher.failures.clear()
        cache.request("a", AudioCacheSource.Lru)
        assertEquals(AudioCacheSource.Lru, cache.cached.value.getValue("a").source)
    }

    private fun cacheTest(block: suspend TestScope.(AudioCacheService) -> Unit) =
        runTest(UnconfinedTestDispatcher()) { block(service(this)) }

    private fun service(scope: TestScope): AudioCacheService {
        val dispatcher = UnconfinedTestDispatcher(scope.testScheduler)
        return AudioCacheService(
            index = index,
            directories = { listOf(primary, secondary) },
            tempDirectory = { temp },
            pendingFile = { pending },
            fetch = { songId, onProgress -> fetcher.fetch(primary, songId, onProgress) },
            scope = scope.backgroundScope,
            io = dispatcher,
            now = { clock },
        )
    }

    private fun TestScope.collectEvents(cache: AudioCacheService): MutableList<AudioCacheEvent> {
        val events = mutableListOf<AudioCacheEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { cache.events.collect(events::add) }
        return events
    }

    private fun audioFile(songId: String) = File(primary, "${AudioCacheUtils.cacheId(songId)}.mp3")

    private fun pendingIds(): List<String> {
        if (!pending.exists()) return emptyList()
        val array = org.json.JSONArray(pending.readText())
        return (0 until array.length()).map(array::getString)
    }

    private fun row(songId: String, source: String, triggers: String? = null) = CacheMetaEntity(
        key = "audio:$songId",
        id = songId,
        type = "audio",
        source = source,
        triggersJson = triggers,
        sizeBytes = 10,
        cachedAt = 1,
        lastAccessedAt = 1,
    )

    private fun writeAudio(directory: File, songId: String, size: Int, extension: String = "mp3") {
        File(directory, "${AudioCacheUtils.cacheId(songId)}.$extension").writeBytes(ByteArray(size))
    }

    /** Stands in for the server: writes a file per song, when and how a test wants. */
    private class FakeFetcher {
        val calls = mutableListOf<String>()
        val cancelled = mutableListOf<String>()
        val failures = mutableMapOf<String, Exception>()
        val sizes = mutableMapOf<String, Long>()

        /** The songs whose file is in place before the download is held at its gate. */
        val early = mutableSetOf<String>()
        private val gates = mutableMapOf<String, CompletableDeferred<Unit>>()
        private val reports = mutableMapOf<String, Pair<Long, Long>>()

        /** Makes the download of [songId] wait until the returned gate is completed. */
        fun hold(songId: String, reportBefore: Pair<Long, Long>? = null): CompletableDeferred<Unit> {
            if (reportBefore != null) reports[songId] = reportBefore
            return CompletableDeferred<Unit>().also { gates[songId] = it }
        }

        fun release(songId: String) {
            gates.remove(songId)
        }

        suspend fun fetch(directory: File, songId: String, onProgress: (Long, Long) -> Unit): DownloadedAudio {
            calls += songId
            reports[songId]?.let { (loaded, total) -> onProgress(loaded, total) }
            if (songId in early) write(directory, songId)
            try {
                gates[songId]?.await()
            } catch (cancellation: kotlinx.coroutines.CancellationException) {
                cancelled += songId
                throw cancellation
            }
            failures[songId]?.let { throw it }
            return write(directory, songId)
        }

        private fun write(directory: File, songId: String): DownloadedAudio {
            val size = sizes[songId] ?: DEFAULT_SIZE
            val file = File(directory, "${AudioCacheUtils.cacheId(songId)}.mp3")
            file.writeBytes(ByteArray(size.toInt()))
            AudioCacheUtils.metadataFile(directory, songId).writeText("{}")
            return DownloadedAudio(file, "audio/mpeg", size)
        }

        companion object {
            const val DEFAULT_SIZE = 64L
        }
    }
}
