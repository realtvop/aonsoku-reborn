# Android native service boundaries

The `android/core` module (`:core`) exposes application-scoped Kotlin services
to the native Compose app in `android/app`. Screens use these services or bind
to `PlaybackService.LocalBinder`; services never hold an `Activity`.

## Service graph and lifetime

`AppServices.getInstance(context)` is the application-scoped graph. It owns
the shared `AuthenticationService`, `PreferencesService`, `LibraryService`,
and `AudioCacheService` instances, and registers the currently running
`AudioService` and `CoordinationService` ports. Registration is replace-safe:
service recreation replaces the old port, and unregistering an old instance
cannot clear a newer one.

`PlaybackService` owns ExoPlayer, MediaSession, foreground playback, audio
focus, persistence, scrobble buffering, queue state, and system media
resources. Its binder exposes both `getService()` for the existing
adapter and `getAudioService()` for native clients. `playbackState` and
`queueState` are independent `StateFlow`s; `events` is a shared event stream.
The service serializes player mutations on the Android main dispatcher.

`LibraryService.getInstance(context)` owns Room, `SyncEngine`, image/cover
cache, typed queries, lyrics, sync state, and data-change notifications. Its
methods are suspend functions where database or network work is involved.

`AudioCacheService.getInstance(context)` owns the audio kept for offline
playback. It outlives `PlaybackService`, so a download does not depend on
anything playing.

- **Files** live in `filesDir/AudioCache/<cacheId>.<ext>` (`cacheId` is the
  URL-safe base64 of the song id, see `AudioCacheUtils`), next to a small
  metadata file with the content type. A file only appears there once its
  transfer is complete.
- **Index**: one `cacheMeta` row of type `audio` per file, with the source
  that decides when the file may go: `explicit` (the user asked; only the
  user removes it), `smart` (a smart-download rule matched; removed by
  `syncSmartDownloads` once no rule does), or `lru` (kept while listening;
  the least recently played go when the pool exceeds `setLruQuota`). Rows of
  type `album` and `playlist` note which collections were downloaded as a
  whole. `initialize()` reconciles rows and files: a row without a file is
  dropped, and a file without a row is adopted as `explicit`.
- **Queue**: `request(songId, source, triggers)` (or the fire-and-forget
  `download`) queues a transfer unless the song is cached or already on its
  way; a higher-ranked request takes the file or the pending transfer over
  (`explicit` > `smart` > `lru`). Four transfers run at a time; a free place
  goes to `lru` (what plays now) first, then `explicit`, then `smart`.
- **Failures**: `AudioUnavailableException` from `NativeDownloadManager.fetch`
  (HTTP 4xx other than 408/429, or a non-audio body such as a Subsonic error
  document) is final. Anything else is passing: an `explicit` transfer stays
  owed (`pending-downloads.json`) and runs again on `resume()` or at the next
  start, the others are dropped and asked for again when they matter. The
  transfer is an OkHttp call that is cancelled with its coroutine, which also
  ends a read waiting on the network.
- **Observation**: `cached` and `downloads` are `StateFlow`s keyed by song
  id; `events` reports `Downloaded`, `Failed`, and `Removed`.

`PlaybackService` requests an `lru` copy of every song it streams and calls
`touch` when it plays a cached file. Deciding what to download (the user's
requests, smart-download rules, quotas from settings) is the app's
`data/offline/OfflineManager`, not a `:core` concern.

`AuthenticationService.getInstance(context)` owns encrypted credentials,
login/fallback probing, server discovery, and typed Subsonic requests.
`PreferencesService.getInstance(context)` owns the DataStore wrapper and
preference change flow. Both services use `applicationContext` and remain
alive when a Capacitor plugin is destroyed.

## Native UI examples

```kotlin
val services = AppServices.getInstance(applicationContext)
val library = services.library
val page = library.getSongs(
    LibraryPagination(limit = 50, offset = 0),
    SongFilter(search = query),
)

val authentication = services.authentication
val credentials = authentication.getCredentials()

val audio = services.audioService()
audio?.events?.collect { event -> /* update native UI */ }
audio?.execute(AudioCommand.Play)
```

For playback service binding, retain the `ServiceConnection` only for the
screen lifecycle. The service itself is not released when the screen or
Capacitor WebView goes away. Each caller must collect and cancel its own flow
job; subscribing or cancelling one client does not replace other clients.

## Coordination runtime

`CoordinationRuntime.getInstance(context)` is the application-scoped owner of
the coordination WebSocket. It registers itself as the `CoordinationService`
port in `AppServices`, handles heartbeats, de-duplication, sequence tracking,
remote commands, snapshot publication, remote projection, and both sides of a
handoff directly against the `AudioService` port, and persists tokens/config
through `CoordinationTokenStore` and the `aonsoku_coordination` preferences.

Clients observe `socketState` (a `StateFlow`) and `events`
(`CoordinationRuntimeEvent`: unconsumed envelopes, acks for tracked commands,
and reconnect requests). Tickets are one-time and short-lived, so the runtime
never reconnects by itself: it emits `ReconnectNeeded` and its owner fetches a
fresh ticket and calls `connect()` again.
