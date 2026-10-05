# Android native service boundaries

The Android Capacitor module exposes application-scoped Kotlin services for
native UI. Native screens should use these services or bind to
`PlaybackService.LocalBinder`; they should not locate a Capacitor plugin or
hold an `Activity`, `WebView`, `Plugin`, or `PluginCall`.

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

## Capacitor adapters

`DataPlugin`, `AudioPlugin`, `BridgePlugin`, `PreferencesPlugin`, and
`AonsokuNativeCoordinationPlugin` remain compatibility adapters. They parse
Capacitor arguments, preserve existing JS method names/fields/units, convert
typed results to JS objects, and forward events with `notifyListeners`.
Coordination protocol JSON is parsed at the coordination adapter boundary and
is passed to the typed audio port for remote commands, projection, snapshots,
and handoff fencing.

The following behavior remains in the TypeScript/WebView layer: route and
screen state, Zustand stores, React Query orchestration, Web Audio playback
when native playback is unavailable, queue replacement confirmation, Web
coordination observation, and UI-specific media-session projection. The
native services provide the long-lived Android state and primitives; they do
not replace those shared cross-runtime UI policies.
