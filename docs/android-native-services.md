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

## Jetpack Compose architecture

The Android application in `android/app` provides a pure Jetpack Compose UI with
Material 3 Expressive theming. It replaces the Capacitor WebView interface for
Android and interacts directly with `AppServices` through standard Android
ViewModels (`SessionViewModel`, `PlaybackViewModel`, `HomeViewModel`,
`LibraryViewModel`, `SearchViewModel`):

- **Playback & Queue**: `PlaybackViewModel` binds to `PlaybackService.LocalBinder`
  and observes `audioService.playbackState` and `audioService.queueState`. It exposes
  flows for currently playing song details, synchronized lyrics (`LrcParser`),
  playback progress, repeat/shuffle controls, and queue modifications.
- **UI Shell**: `AonsokuApp` orchestrates Compose `NavHost` routing, edge-to-edge
  insets, docked `MiniPlayerBar`, expandable `FullscreenPlayer`, and `QueueSheet`
  bottom sheets.
- **Library & Data**: `LibraryViewModel`, `HomeViewModel`, and `SearchViewModel`
  query `LibraryService` Room entities and paging helpers, delivering instant
  offline-first responses and reactive updates.

## Capacitor adapters

`DataPlugin`, `AudioPlugin`, `BridgePlugin`, `PreferencesPlugin`, and
`AonsokuNativeCoordinationPlugin` remain compatibility adapters for the legacy
Capacitor WebView. They parse Capacitor arguments, preserve existing JS method
names/fields/units, convert typed results to JS objects, and forward events with
`notifyListeners`.

Coordination protocol JSON is parsed at the coordination adapter boundary and
is passed to the typed audio port for remote commands, projection, snapshots,
and handoff fencing.
