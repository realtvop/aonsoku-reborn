# Android native service boundaries

The `android/core` module (`:core`) exposes application-scoped Kotlin services
to the native Compose app in `android/app`. Screens use these services or bind
to `PlaybackService.LocalBinder`; services never hold an `Activity`.

## Service graph and lifetime

`AppServices.getInstance(context)` is the application-scoped graph. It owns
the shared `AuthenticationService`, `PreferencesService`, and
`LibraryService` instances, and registers the currently running
`AudioService` and `CoordinationService` ports. Registration is replace-safe:
service recreation replaces the old port, and unregistering an old instance
cannot clear a newer one.

`PlaybackService` owns ExoPlayer, MediaSession, foreground playback, audio
focus, downloads, persistence, scrobble buffering, queue state, and system
media resources. Its binder exposes both `getService()` for the existing
adapter and `getAudioService()` for native clients. `playbackState` and
`queueState` are independent `StateFlow`s; `events` is a shared event stream.
The service serializes player mutations on the Android main dispatcher.

`LibraryService.getInstance(context)` owns Room, `SyncEngine`, image/cover
cache, typed queries, lyrics, sync state, and data-change notifications. Its
methods are suspend functions where database or network work is involved.

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
