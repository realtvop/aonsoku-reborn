package github.realtvop.aonsoku.plugins

import github.realtvop.aonsoku.plugins.audio.AudioCommand
import github.realtvop.aonsoku.plugins.audio.AudioCommandResult
import github.realtvop.aonsoku.plugins.audio.AudioEvent
import github.realtvop.aonsoku.plugins.audio.AudioPlaybackSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioQueueSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioRemotePlaybackSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioService
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.coordination.CoordinationService
import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import org.mockito.Mockito.mock

class NativeServiceBoundaryTest {
    @Test
    fun appServicesReplacesOnlyTheServiceThatWasDestroyed() {
        val services = AppServices(
            mock(AuthenticationService::class.java),
            mock(PreferencesService::class.java),
            mock(LibraryService::class.java),
        )
        val firstAudio = FakeAudioService()
        val secondAudio = FakeAudioService()
        val firstCoordination = mock(CoordinationService::class.java)
        val secondCoordination = mock(CoordinationService::class.java)

        services.registerAudioService(firstAudio)
        services.registerCoordinationService(firstCoordination)
        services.registerAudioService(secondAudio)
        services.registerCoordinationService(secondCoordination)

        services.unregisterAudioService(firstAudio)
        services.unregisterCoordinationService(firstCoordination)

        assertSame(secondAudio, services.audioService())
        assertSame(secondCoordination, services.coordinationService())

        services.unregisterAudioService(secondAudio)
        services.unregisterCoordinationService(secondCoordination)
        assertEquals(null, services.audioService())
        assertEquals(null, services.coordinationService())
    }

    @Test
    fun audioSubscribersAreIndependentAndCommandsReportFailures() = runBlocking {
        val service = FakeAudioService()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val firstEvents = mutableListOf<AudioEvent>()
        val secondEvents = mutableListOf<AudioEvent>()
        val firstJob = scope.launch { service.events.collect(firstEvents::add) }
        val secondJob = scope.launch { service.events.collect(secondEvents::add) }

        service.emit(AudioEvent.Error("test", "first", AudioPlaybackSnapshot()))
        firstJob.cancel()
        service.emit(AudioEvent.Error("test", "second", AudioPlaybackSnapshot()))

        assertEquals(1, firstEvents.size)
        assertEquals(2, secondEvents.size)
        assertEquals("second", (secondEvents.last() as AudioEvent.Error).message)

        val failure = service.execute(AudioCommand.Seek(12.5))
        assertEquals(
            AudioCommandResult.Failure("not_ready", "fake service rejected command"),
            failure,
        )
        assertEquals(AudioCommand.Seek(12.5), service.commands.single())
        scope.cancel()
    }

    @Test
    fun typedServiceStateAndLegacyFullStateKeepSecondsAndQueueFields() {
        val service = FakeAudioService()
        val playback = AudioPlaybackSnapshot(
            state = "playing",
            songId = "song-1",
            currentTimeSeconds = 12.5,
            durationSeconds = 180.0,
            isPlaying = true,
        )
        service.setPlayback(playback)

        assertEquals("playing", service.playbackState.value.state)
        assertEquals(12.5, service.playbackState.value.currentTimeSeconds, 0.0)
        assertEquals(12.5, service.getFullState()?.getDouble("currentTime"))
        assertEquals("song-1", service.getFullState()?.getString("currentSongId"))
        assertEquals("song-1", service.queueState.value.currentSong?.id)
    }

    private class FakeAudioService : AudioService {
        private val playback = MutableStateFlow(AudioPlaybackSnapshot())
        private val queue = MutableStateFlow(AudioQueueSnapshot())
        private val eventFlow = MutableSharedFlow<AudioEvent>(extraBufferCapacity = 16)
        val commands = mutableListOf<AudioCommand>()

        override val playbackState = playback
        override val queueState = queue
        override val events = eventFlow

        fun emit(event: AudioEvent) {
            eventFlow.tryEmit(event)
        }

        fun setPlayback(snapshot: AudioPlaybackSnapshot) {
            playback.value = snapshot
            queue.value = AudioQueueSnapshot(
                currentSong = snapshot.songId?.let {
                    github.realtvop.aonsoku.plugins.audio.QueueSong(
                        id = it,
                        title = it,
                        artist = "artist",
                        artistId = null,
                        album = "album",
                        albumId = null,
                        duration = snapshot.durationSeconds,
                        coverArtId = null,
                        streamUrl = "aonsoku-media://stream?id=$it",
                        cachedFileUri = null,
                    )
                },
            )
        }

        override suspend fun execute(command: AudioCommand): AudioCommandResult {
            commands += command
            return AudioCommandResult.Failure("not_ready", "fake service rejected command")
        }

        override fun requestAudioFocus() = true
        override fun getSystemVolume() = 0.5
        override fun setSystemVolume(value: Double) = value
        override fun getSleepTimerRemaining() = 0.0
        override fun setRequestId(requestId: String?) = Unit
        override fun getFullState(): JSONObject = JSONObject().apply {
            put("currentTime", playback.value.currentTimeSeconds)
            put("duration", playback.value.durationSeconds)
            put("isPlaying", playback.value.isPlaying)
            put("currentSongId", playback.value.songId)
        }
        override fun pauseAndGetFullState() = getFullState()
        override fun executeRemoteControlCommand(command: JSONObject) = true
        override fun applyRemotePlaybackSnapshot(snapshot: AudioRemotePlaybackSnapshot) = Unit
        override fun clearRemotePlaybackProjection() = Unit
        override fun prepareHandoff(
            snapshot: JSONObject,
            autoplay: Boolean,
            completion: (Boolean) -> Unit,
        ) = completion(false)
        override fun rollbackHandoff() = Unit
    }
}
