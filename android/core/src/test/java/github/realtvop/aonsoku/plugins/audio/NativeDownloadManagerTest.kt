package github.realtvop.aonsoku.plugins.audio

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NativeDownloadManagerTest {
    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var server: HttpServer
    private lateinit var cache: File
    private lateinit var temp: File
    private var handler: (HttpExchange) -> Unit = { it.respond(200, "audio/mpeg", SONG) }
    private val queries = mutableListOf<String>()
    private var signedIn = true

    @Before
    fun setUp() {
        cache = folder.newFolder("AudioCache")
        temp = folder.newFolder("temp")
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            executor = Executors.newCachedThreadPool()
            createContext("/rest/stream") { exchange ->
                queries += exchange.requestURI.rawQuery.orEmpty()
                handler(exchange)
            }
            start()
        }
    }

    @After
    fun tearDown() {
        server.stop(0)
    }

    @Test
    fun aSongIsWrittenToTheCacheDirectoryWithItsNote() = runBlocking {
        handler = { it.respond(200, "audio/flac; charset=binary", SONG) }
        val progress = mutableListOf<Pair<Long, Long>>()

        val audio = downloader().fetch("song 1", maxBitRate = 320, format = "flac") { loaded, total ->
            progress += loaded to total
        }

        val expected = File(cache, "${AudioCacheUtils.cacheId("song 1")}.flac")
        assertEquals(expected, audio.file)
        assertArrayEquals(SONG, expected.readBytes())
        assertEquals(SONG.size.toLong(), audio.sizeBytes)
        assertEquals("audio/flac; charset=binary", audio.contentType)
        assertTrue(AudioCacheUtils.metadataFile(cache, "song 1").readText().contains("\"songId\":\"song 1\""))
        assertEquals(SONG.size.toLong() to SONG.size.toLong(), progress.last())
        assertEquals(emptyList<File>(), temp.listFiles().orEmpty().toList())

        val query = queries.single()
        assertTrue(query, "id=song+1" in query)
        assertTrue(query, "u=tester" in query)
        assertTrue(query, "maxBitRate=320" in query)
        assertTrue(query, "format=flac" in query)
        assertTrue(query, "estimateContentLength=true" in query)
    }

    @Test
    fun aCopyInAnotherFormatIsReplaced() = runBlocking {
        val old = File(cache, "${AudioCacheUtils.cacheId("song")}.flac").apply { writeText("old copy") }

        val audio = downloader().fetch("song")

        assertFalse(old.exists())
        assertEquals("mp3", audio.file.extension)
        assertEquals(1, cache.listFiles().orEmpty().count { it.extension != "json" })
    }

    @Test
    fun anErrorDocumentIsNotStoredAsAudio() = runBlocking {
        // Subsonic answers a request it cannot serve with HTTP 200 and a document.
        handler = {
            it.respond(200, "application/json", """{"subsonic-response":{"status":"failed"}}""".toByteArray())
        }

        val error = failure { downloader().fetch("missing") }

        assertTrue(error is AudioUnavailableException)
        assertNothingWasWritten()
    }

    @Test
    fun aRefusalIsFinalAndABusyServerIsNot() = runBlocking {
        handler = { it.respond(404, "text/plain", "no such song".toByteArray()) }
        assertTrue(failure { downloader().fetch("song") } is AudioUnavailableException)

        handler = { it.respond(503, "text/plain", "restarting".toByteArray()) }
        assertFalse(failure { downloader().fetch("song") } is AudioUnavailableException)

        handler = { it.respond(429, "text/plain", "slow down".toByteArray()) }
        assertFalse(failure { downloader().fetch("song") } is AudioUnavailableException)

        handler = { it.respond(200, "audio/mpeg", ByteArray(0)) }
        assertFalse(failure { downloader().fetch("song") } is AudioUnavailableException)
        assertNothingWasWritten()
    }

    @Test
    fun beingSignedOutIsNotARefusalOfTheServer() = runBlocking {
        signedIn = false

        val error = failure { downloader().fetch("song") }

        assertFalse(error is AudioUnavailableException)
        assertTrue(queries.isEmpty())
    }

    @Test
    fun cancellingAbortsTheTransferAndLeavesNothingBehind() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        handler = { exchange ->
            exchange.responseHeaders.add("Content-Type", "audio/mpeg")
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.write(ByteArray(1024))
            exchange.responseBody.flush()
            started.complete(Unit)
            // The rest never comes while the test holds the latch.
            release.await(30, TimeUnit.SECONDS)
            runCatching { exchange.close() }
        }

        val download = async(Dispatchers.Default) { downloader().fetch("song") }
        started.await()
        // A reader blocked on the socket has to be woken by closing it.
        withTimeout(5_000) { download.cancelAndJoin() }
        release.countDown()

        assertTrue(download.isCancelled)
        assertNothingWasWritten()
    }

    @Test
    fun onlyDocumentsAreToldApartFromAudio() {
        for (type in listOf("audio/mpeg", "audio/flac", "application/ogg", "application/octet-stream", "video/mp4")) {
            assertTrue(type, NativeDownloadManager.isAudio(type))
        }
        for (type in listOf("application/json", "text/xml; charset=utf-8", "application/xml", "text/html", "text/plain")) {
            assertFalse(type, NativeDownloadManager.isAudio(type))
        }
    }

    private fun downloader() = NativeDownloadManager(
        cacheDirectory = { cache },
        tempDirectory = { temp },
        credentials = {
            if (signedIn) {
                ServerCredentials(
                    serverUrl = "http://127.0.0.1:${server.address.port}/",
                    username = "tester",
                    password = "secret",
                    authType = "token",
                    protocolVersion = "1.16.1",
                    serverType = "navidrome",
                    fallbackUrl = null,
                )
            } else {
                null
            }
        },
    )

    private suspend fun failure(block: suspend () -> Unit): IOException {
        try {
            block()
        } catch (error: IOException) {
            return error
        }
        fail("Expected the download to fail")
        throw AssertionError()
    }

    private fun assertNothingWasWritten() {
        assertEquals(emptyList<File>(), cache.listFiles().orEmpty().toList())
        assertEquals(emptyList<File>(), temp.listFiles().orEmpty().toList())
    }

    private fun HttpExchange.respond(status: Int, contentType: String, body: ByteArray) {
        responseHeaders.add("Content-Type", contentType)
        sendResponseHeaders(status, if (body.isEmpty()) -1 else body.size.toLong())
        if (body.isNotEmpty()) responseBody.use { it.write(body) }
        close()
    }

    private companion object {
        val SONG = ByteArray(200_000) { (it % 251).toByte() }
    }
}
