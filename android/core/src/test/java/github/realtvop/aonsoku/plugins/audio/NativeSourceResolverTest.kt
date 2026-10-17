package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import android.net.Uri
import android.util.Base64
import android.util.Log
import github.realtvop.aonsoku.plugins.bridge.AndroidCredentialStore
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.mockito.MockedStatic
import org.mockito.Mockito
import java.io.File

class NativeSourceResolverTest {

    private lateinit var mockedUri: MockedStatic<Uri>
    private lateinit var mockedBase64: MockedStatic<Base64>
    private lateinit var mockedLog: MockedStatic<Log>

    @Before
    fun setUp() {
        mockedUri = Mockito.mockStatic(Uri::class.java)
        mockedUri.`when`<Uri> { Uri.parse(Mockito.anyString()) }.thenAnswer { invocation ->
            val urlString = invocation.getArgument<String>(0)
            val mockUri = Mockito.mock(Uri::class.java)
            Mockito.`when`(mockUri.getQueryParameter(Mockito.anyString())).thenAnswer { paramInvocation ->
                val paramName = paramInvocation.getArgument<String>(0)
                val queryIndex = urlString.indexOf('?')
                if (queryIndex != -1) {
                    val query = urlString.substring(queryIndex + 1)
                    val pairs = query.split('&')
                    for (pair in pairs) {
                        val idx = pair.indexOf('=')
                        if (idx != -1) {
                            val key = pair.substring(0, idx)
                            val value = pair.substring(idx + 1)
                            if (key == paramName) {
                                return@thenAnswer java.net.URLDecoder.decode(value, "UTF-8")
                            }
                        }
                    }
                }
                null
            }
            mockUri
        }

        mockedBase64 = Mockito.mockStatic(Base64::class.java)
        mockedBase64.`when`<String> { 
            Base64.encodeToString(Mockito.any(ByteArray::class.java), Mockito.anyInt()) 
        }.thenAnswer { invocation ->
            val input = invocation.getArgument<ByteArray>(0)
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(input)
        }

        mockedLog = Mockito.mockStatic(Log::class.java)
        mockedLog.`when`<Int> { Log.d(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
        mockedLog.`when`<Int> { Log.i(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
        mockedLog.`when`<Int> { Log.w(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
        mockedLog.`when`<Int> { Log.e(Mockito.anyString(), Mockito.anyString()) }.thenReturn(0)
    }

    @After
    fun tearDown() {
        mockedUri.close()
        mockedBase64.close()
        mockedLog.close()
    }

    @Rule
    @JvmField
    val tempFolder = TemporaryFolder()

    private fun createSong(id: String, streamUrl: String, cachedFileUri: String? = null): QueueSong {
        return QueueSong(
            id = id,
            title = "Song $id",
            artist = "Artist",
            artistId = null,
            album = "Album",
            albumId = null,
            duration = 180.0,
            coverArtId = null,
            streamUrl = streamUrl,
            cachedFileUri = cachedFileUri
        )
    }

    @Test
    fun testResolveCachedFileUri() {
        val context = Mockito.mock(Context::class.java)
        val filesDir = tempFolder.newFolder("files")
        val cacheDir = tempFolder.newFolder("cache")
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.cacheDir).thenReturn(cacheDir)

        val cachedFile = File(filesDir, "test_cached_song.mp3")
        cachedFile.writeText("audio data")

        val song = createSong(
            id = "song-1",
            streamUrl = "http://stream/1",
            cachedFileUri = cachedFile.absolutePath
        )

        val credentialStore = Mockito.mock(AndroidCredentialStore::class.java)
        val resolver = NativeSourceResolver(context, credentialStore)
        val result = resolver.resolveSource(song)

        assertNotNull(result)
        assertEquals("native-file", result?.second)
        assertTrue(result?.first?.startsWith("file:/") ?: false)
    }

    @Test
    fun testResolveFromCacheDirectories() {
        val context = Mockito.mock(Context::class.java)
        val filesDir = tempFolder.newFolder("files")
        val cacheDir = tempFolder.newFolder("cache")
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.cacheDir).thenReturn(cacheDir)

        val cacheId = AudioCacheUtils.cacheId("song-abc")
        val audioCacheDir = File(filesDir, AudioCacheUtils.CACHE_DIRECTORY_NAME).apply { mkdirs() }
        val cachedFile = File(audioCacheDir, "$cacheId.mp3")
        cachedFile.writeText("cached mp3 data")

        val song = createSong(
            id = "song-abc",
            streamUrl = "http://stream/abc"
        )

        val credentialStore = Mockito.mock(AndroidCredentialStore::class.java)
        val resolver = NativeSourceResolver(context, credentialStore)
        val result = resolver.resolveSource(song)

        assertNotNull(result)
        assertEquals("native-file", result?.second)
        assertTrue(result?.first?.contains("$cacheId.mp3") ?: false)
    }

    @Test
    fun testResolveAuthenticatedStreamUrl() {
        val context = Mockito.mock(Context::class.java)
        val filesDir = tempFolder.newFolder("files")
        val cacheDir = tempFolder.newFolder("cache")
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.cacheDir).thenReturn(cacheDir)

        val credentialStore = Mockito.mock(AndroidCredentialStore::class.java)
        val credentials = ServerCredentials(
            serverUrl = "https://navidrome.example.com",
            username = "testuser",
            password = "testpassword",
            authType = "token",
            protocolVersion = "1.16.0",
            serverType = "subsonic",
            fallbackUrl = null
        )
        Mockito.`when`(credentialStore.retrieve()).thenReturn(credentials)

        val song = createSong(
            id = "song-stream-id",
            streamUrl = "aonsoku-media://stream?id=song-stream-id"
        )

        val resolver = NativeSourceResolver(context, credentialStore)
        val result = resolver.resolveSource(song)

        assertNotNull(result)
        assertEquals("stream", result?.second)
        val resolvedUrl = result?.first ?: ""
        assertTrue(resolvedUrl.startsWith("https://navidrome.example.com/rest/stream"))
        assertTrue(resolvedUrl.contains("u=testuser"))
        assertTrue(resolvedUrl.contains("id=song-stream-id"))
        assertTrue(resolvedUrl.contains("estimateContentLength=true"))
    }

    @Test
    fun testDirectHttpUrlPassThroughWithCredentials() {
        val context = Mockito.mock(Context::class.java)
        val filesDir = tempFolder.newFolder("files")
        val cacheDir = tempFolder.newFolder("cache")
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.cacheDir).thenReturn(cacheDir)

        val credentialStore = Mockito.mock(AndroidCredentialStore::class.java)
        val credentials = ServerCredentials(
            serverUrl = "https://navidrome.example.com",
            username = "testuser",
            password = "testpassword",
            authType = "token",
            protocolVersion = "1.16.0",
            serverType = "subsonic",
            fallbackUrl = null
        )
        Mockito.`when`(credentialStore.retrieve()).thenReturn(credentials)

        val song = createSong(
            id = "radio-1",
            streamUrl = "http://radio.example.com/stream.mp3"
        )

        val resolver = NativeSourceResolver(context, credentialStore)
        val result = resolver.resolveSource(song)

        assertNotNull(result)
        assertEquals("stream", result?.second)
        assertEquals("http://radio.example.com/stream.mp3", result?.first)
    }

    @Test
    fun testRadioUrlPassthrough() {
        val context = Mockito.mock(Context::class.java)
        val filesDir = tempFolder.newFolder("files")
        val cacheDir = tempFolder.newFolder("cache")
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.cacheDir).thenReturn(cacheDir)

        val credentialStore = Mockito.mock(AndroidCredentialStore::class.java)
        Mockito.`when`(credentialStore.retrieve()).thenReturn(null)

        val song = createSong(
            id = "radio-2",
            streamUrl = "https://radio.example.com/stream"
        )

        val resolver = NativeSourceResolver(context, credentialStore)
        val result = resolver.resolveSource(song)

        assertNotNull(result)
        assertEquals("stream", result?.second)
        assertEquals("https://radio.example.com/stream", result?.first)
    }

    @Test
    fun testAonsokuStreamWithoutCredentialsReturnsNull() {
        val context = Mockito.mock(Context::class.java)
        val filesDir = tempFolder.newFolder("files")
        val cacheDir = tempFolder.newFolder("cache")
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.cacheDir).thenReturn(cacheDir)

        val credentialStore = Mockito.mock(AndroidCredentialStore::class.java)
        Mockito.`when`(credentialStore.retrieve()).thenReturn(null)

        val song = createSong(
            id = "song-no-cred",
            streamUrl = "aonsoku-media://stream?id=song-no-cred"
        )

        val resolver = NativeSourceResolver(context, credentialStore)
        val result = resolver.resolveSource(song)

        assertNull("Should return null when credentials are missing", result)
    }

    @Test
    fun testAonsokuStreamWithMaxBitRateAndFormat() {
        val context = Mockito.mock(Context::class.java)
        val filesDir = tempFolder.newFolder("files")
        val cacheDir = tempFolder.newFolder("cache")
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.cacheDir).thenReturn(cacheDir)

        val credentialStore = Mockito.mock(AndroidCredentialStore::class.java)
        val credentials = ServerCredentials(
            serverUrl = "http://192.168.1.100:4533",
            username = "user",
            password = "pass",
            authType = "password",
            protocolVersion = "1.16.0",
            serverType = "navidrome",
            fallbackUrl = null
        )
        Mockito.`when`(credentialStore.retrieve()).thenReturn(credentials)

        val song = createSong(
            id = "song-123",
            streamUrl = "aonsoku-media://stream?id=song-123&maxBitRate=320&format=mp3"
        )

        val resolver = NativeSourceResolver(context, credentialStore)
        val result = resolver.resolveSource(song)

        assertNotNull(result)
        assertEquals("stream", result?.second)
        val resolvedUrl = result?.first ?: ""
        assertTrue("Should use HTTP base URL", resolvedUrl.startsWith("http://192.168.1.100:4533/rest/stream"))
        assertTrue("Should include maxBitRate", resolvedUrl.contains("maxBitRate=320"))
        assertTrue("Should include format", resolvedUrl.contains("format=mp3"))
        assertTrue("Should include estimateContentLength", resolvedUrl.contains("estimateContentLength=true"))
    }
}
