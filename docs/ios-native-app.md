# Native iOS app

The iOS app is a SwiftUI application built for iOS 26 and Liquid Glass. It
replaces the Capacitor/WebView host that previously wrapped the web UI. Android
and Electron keep using the shared TypeScript app; iOS shares no runtime code
with them, only the server protocols (Subsonic/OpenSubsonic, coordination
`/v1/*` + WebSocket protocol version 1) and the translation files.

Apple Music is the interaction reference: tab bar with a search tab, a mini
player in the tab bar accessory, a zoom-transition Now Playing screen, and
context menus on every song, album, artist, and playlist.

## Platform

| Item | Value |
| --- | --- |
| Minimum OS | iOS 26.0 (iPhone and iPad) |
| Toolchain | Xcode 26, Swift 6.2 compiler, Swift 5 language mode |
| Bundle identifier | `github.realtvop.aonsoku` (unchanged, so upgrades keep data) |
| Background modes | `audio`, `fetch` (BGTask `github.realtvop.aonsoku.sync.refresh`) |

## Layout

```text
ios/
  Aonsoku.xcodeproj      App project. Uses synchronized folders, so adding a
                         Swift file under ios/Aonsoku needs no project edit.
  Aonsoku/               App target: views, navigation, composition root.
    App/                 @main app, AppDelegate, root and tab views.
    DesignSystem/        Router, theme, artwork, rows, shelves, menus
                         chrome, marquee, toasts, formatters.
    Features/<Area>/     One folder per screen family: Account, Album,
                         Artist, Devices, Home, Library, Login, Menus,
                         Player (mini player, Now Playing, lyrics, queue),
                         Playlist, Search, Settings, Song.
    Resources/           Asset catalog, Info.plist.
  native-locales/        Strings only the native app uses, under `native.*`.
  AonsokuKit/            Swift package. All logic and observable state.
    Sources/AonsokuKit/  Services, API client, stores (see below).
    Tests/AonsokuKitTests/
```

The translation JSON files in `src/i18n/locales/` are bundled into the app as
a folder reference; they stay the single source of translations for every
platform. `ios/native-locales/<language>.json` overlays the few strings that
exist only in the native app. `node scripts/check-ios-strings.mjs` checks that
every key the Swift sources use exists in English.

## Ownership boundary

`AonsokuKit` owns every piece of logic and state: networking, persistence,
playback, sync, caching, lyrics, coordination, settings, and the
`@MainActor @Observable` stores the UI binds to. It has no UIKit views except
the shake-to-open native debug controller, and it never imports Capacitor.

The app target owns presentation only: views, navigation, animation,
haptics, and presentation state (selected tab, sheet routing, scroll
positions, list filters). A view calls the store for product behavior and
renders its state. The album-list views persist their presentation-only sort
preference through the shared `PreferencesService`; they do not perform
library, network, playback, or coordination work directly.

Long-lived services are created once by `AppServices` and stores by
`AppModel` (the composition root), which the app injects into the SwiftUI
environment. The app renders a lightweight branded launch view before creating
the service graph off the main actor, so database migration and service
construction never leave the first frame blank.

`AppModel` records the library owner as the normalized primary server URL and
username. Signing out clears observable account state but keeps the offline
library for the same account. Before a different account activates, it cancels
old work and removes server metadata, playback/history rows, audio and artwork
caches, pins, lyrics selections and the prior coordination registration so
process-wide services cannot expose the previous account's content. Signing
back into the same account resumes its preserved coordination registration.

That removal never happens without the user's say-so. When a sign-in or a
launch restore finds a library recorded for another username, for the same
username at another server address, or with no recorded owner, `AppModel`
holds a pending `AccountSwitchRequest` instead of activating. `RootView` keeps
the sign-in screen up and `AccountSwitchAlert` asks the user to erase the old
library, keep it (offered only when it may be the same account, as after a
server address change), or cancel the sign-in. The request survives a
relaunch, and changing the server address in Settings → Server goes through
`AppModel.updateServerUrls`, which moves the recorded owner with it.

## Services (AonsokuKit)

| Service | Responsibility |
| --- | --- |
| `AudioService` | Long-lived AVQueuePlayer playback with deterministic next-item preloading and gapless adoption, queue engine, shuffle/repeat, downloads, stream cache, scrobbling, playback persistence, recovery, sleep timer, Now Playing info and remote commands, handoff preparation/rollback. |
| `LibraryService` | GRDB library database, metadata sync and scheduling, typed library queries, lyrics cache, cover/avatar disk cache. |
| `AuthenticationService` | Keychain credentials, login with token/password and primary/fallback probing, server info, authenticated Subsonic requests and URL building. |
| `PreferencesService` | Key/value preferences in the library database, play history, change notifications. |
| `CoordinationService` | Coordination token/config storage, HTTP requests, realtime WebSocket transport, heartbeats, reconnect policy, native snapshot publication, remote command execution, and handoff transactions against `AudioService`. |
| `AppLifecycleService` | App/scene lifecycle fan-out to audio, coordination, and background URL sessions. |

## Stores and UI contracts

Stateful stores are `@MainActor @Observable public final class` types. Views
read their properties and call their async methods; stores translate service
callbacks into main-actor state. `LibraryRepository` and `ArtworkProvider` are
thread-safe helper classes shared by those stores and the presentation layer;
they do not expose observable state.

| Store | State and actions |
| --- | --- |
| `SessionStore` | Restore/sign-in state, active server (primary/fallback), user, login, logout, server URL updates. |
| `SettingsStore` | Every user setting (table below) with persistence and one-time migration from the former web-app preference keys. |
| `LibraryRepository` | Async queries for albums, artists, songs, playlists, genres, radios, search, artist/album info; local database first when offline or synced, Subsonic otherwise. |
| `FavoritesStore` | Optimistic starred state for songs, albums, and artists, shared by every screen. |
| `PlaylistsStore` | Playlist list plus create, edit, delete, add songs, remove songs. |
| `PinnedHomeStore` | Albums and playlists pinned to Home. |
| `PlayerStore` | Now playing item, progress, buffering, repeat/shuffle, queue sections, sleep timer, volume, queue replacement confirmation, remote playback target. |
| `LyricsStore` | Lyrics for the current song from Navidrome, LRCLIB, or a custom server; synced lines, translations, romaji, per-song selection, offset, and disable state. |
| `DownloadsStore` | Explicit and smart downloads, stream cache, cover cache, pool statistics, cache browser, quotas. |
| `LibrarySyncStore` | Sync phase/tier/progress, last sync time, sync now, cancel. |
| `CoordinationStore` | Cross-device setup, connection state, devices, remote playback snapshots, remote control, handoff status. |
| `HomeStore` | Home carousel and album sections, refreshed on pull and every two minutes for Recently Played. |
| `RadioStore` | Internet radio stations: list, create, edit, delete. |
| `ListeningHistoryStore` | Songs listened to for at least ten seconds, newest first, kept in the native play history. |
| `NetworkMonitor` | Online/offline and metered state. |
| `ArtworkProvider` | Downsampled cover/avatar images through the shared disk cache, plus artwork color palettes for Now Playing. |
| `Localizer` | Translation lookup with i18next semantics (nested keys, `{{name}}` interpolation, CLDR plural suffixes, English fallback), the native-only overlay, and the in-app language override. |
| `ToastCenter` | Transient confirmations and errors shown above the tab bar. |
| `PagedCollection` | Paged list loading with retry for the long library lists. |

`LibrarySyncStore` is the sole owner of foreground sync scheduling, including
connectivity, metered-network and cover-art options. `SyncScheduler` only owns
the system background refresh path when `AppModel` initializes the library
with automatic foreground sync disabled.

## Navigation and screens

- **Tabs**: Home, Library, Search, with independent native navigation stacks.
  Compact widths hide the system tab bar and use `CompactTabBar`. One
  animated progress moves the existing controls and glass backgrounds from
  an expanded tab row to a leading tab, center player and trailing Search
  circle. Tab roles stay constant throughout the animation. Vertical user
  scrolling minimizes/expands the dock; horizontal shelves and programmatic
  scrolling do not. Tapping the minimized leading tab expands the choices;
  tapping the selected expanded tab returns to its root. The dock hides with
  the keyboard, respects Reduce Motion, and stays expanded at accessibility
  text sizes. Regular widths retain the system sidebar-adaptable tab style.
- **Mini player**: the same `MiniPlayer` in both layouts. The compact dock
  animates its artwork, text, spacing and Next control with the dock's progress;
  the regular-width system `tabViewBottomAccessory` supplies its placement.
  Tapping it opens Now Playing with a zoom transition; it also shows remote
  playback when controlling another device.
- **Now Playing**: artwork-derived animated mesh gradient, artwork that
  shrinks while paused, marquee title, favorite and more menus, scrubber,
  transport, volume, and a bottom bar for lyrics, AirPlay, Aonsoku devices,
  and the queue. Lyrics and queue replace the large artwork with a compact
  header, as in Apple Music.
- **Home**: other devices' playback, featured albums, pinned items, Recently
  Played, Most Played, Recently Added, Explore. Pull to refresh runs an
  incremental sync. The avatar opens the account sheet.
- **Library**: Playlists, Artists, Albums, Songs, Favorites, Downloaded,
  Genres, Radio (unless hidden), followed by a Recently Added grid.
- **Detail screens**: album, artist, playlist, genre, album lists by filter,
  artist discography and tracks, song info.
- **Search**: browse genres when idle, scoped results (top, artists, albums,
  songs) while typing.
- **Account sheet** (the avatar on Home and Library, as in Apple Music):
  user and server, connection and sync status, then Server, Appearance,
  Language, Playback, Lyrics, Content, Storage (with the cache manager),
  Cross-Device, Privacy, About, and Sign Out. Shaking the device opens the
  native player debug screen, as before.

## Settings parity

| Web setting | Native behavior |
| --- | --- |
| Server: primary URL, fallback URL, active URL/type | Same fields, validation, and save flow. |
| Appearance: theme mode, light theme, dark theme | Appearance mode plus the same named themes, applied as tint and background palettes. |
| Appearance: auto full-screen player | Opens Now Playing when a song, album, playlist, artist, or station starts playing. |
| Appearance: album cover for songs | Same behavior for song artwork and cover sync. |
| Appearance: pointer cursors | Not applicable; iPadOS draws its own pointer effects. |
| Fullscreen: background color intensity | Intensity of the Now Playing artwork gradient. |
| Language | In-app language picker (system default plus the 18 bundled languages). |
| Audio: haptic feedback | Gates all sensory feedback. |
| Audio: ReplayGain (enabled, track/album, pre-amp, default gain) | Applied by native playback. |
| Audio: lyrics (prefer synced, translation, source priority, custom server URL/password) | Same options; priority list is reorderable. |
| Audio: play history size | Same limit (10–1000). |
| Audio: browser Picture in Picture | Not applicable on iOS (no document Picture in Picture); omitted. |
| Content: hide radios | Hides Radio in Library and Search. |
| Storage: library sync, cover art sync, cover concurrency, sync now/cancel | Same; library caching is always on, as in the former iOS app. |
| Storage: smart downloads (favorite songs, favorite playlists) | Same rules. |
| Storage: stream cache and cover cache quotas, per-pool clear, clear all | Same quotas and actions. |
| Storage: cache manager | Native list with filter and swipe to delete. |
| Cross-device: server, identity URL, device name, connect/disconnect, devices rename/revoke, delete data | Same. |
| Privacy: LRCLIB | Same. |
| Desktop settings | Not applicable on iOS. |

## Data continuity

The app keeps the bundle identifier, so an upgrade from the Capacitor build
keeps the keychain credentials, the GRDB library database, cached audio and
covers, playback state, and coordination tokens. On first launch
`SettingsMigration` reads the former web-app preference entries
(`player_store`, `theme_store`, `lang_store`, `app_store`, `cache_settings`,
`pinned_home_store`, `player_history`) from the preferences table, writes the
native settings, pins, play history, and lyrics selections, and records that
the migration ran. `LegacyWebDataImporter` then reads what the WebView kept in
IndexedDB (the cache index, cached lyrics, and custom lyrics) once and moves it
into native storage; a failed read is retried on the next launch.

## Validation

```bash
# AonsokuKit unit tests (first available iPhone simulator, or IOS_SIMULATOR_ID)
./scripts/test-ios-native.sh

# App build for the simulator
xcodebuild -project ios/Aonsoku.xcodeproj -scheme Aonsoku \
  -destination 'generic/platform=iOS Simulator' build

# Translation keys used by the Swift sources
node scripts/check-ios-strings.mjs

# Repository lint (also runs from the pre-commit hook)
pnpm run lint
```

`.github/workflows/build-ios.yml` runs the same tests and strings check on an
Xcode 26 runner, archives `ios/Aonsoku.xcodeproj` with the short commit hash in
`AonsokuBuildHash`, and publishes an unsigned `Aonsoku-unsigned.ipa`. Tag
releases call that workflow and attach a versioned unsigned iOS IPA to the
GitHub release. Release versioning updates `MARKETING_VERSION` in the native
Xcode project; Capacitor versioning remains Android-only.
