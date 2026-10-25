# Native iOS app

The iOS app is a SwiftUI application built for iOS 26 and Liquid Glass. It
replaces the Capacitor/WebView host that previously wrapped the web UI. Android
and Electron keep using the shared TypeScript app; iOS shares no runtime code
with them, only the server protocols (Subsonic/OpenSubsonic, coordination
`/v1/*` + WebSocket protocol version 1) and the translation files.

Interaction stays native: tab bar with a search tab, a mini player in the tab
bar accessory, a vertically sliding Now Playing screen, Liquid Glass bars and
controls, swipe actions, and context menus on every song, album, artist, and
playlist. The visual language follows the web app instead, so Aonsoku looks
the same on every platform (see [Design language](#design-language)).

## Design language

- **Colors**: every theme, the default light and dark ones included, paints
  the web palette from `src/themes.css` (`DesignSystem/Theme.swift`). Pages
  use the web body color `--background-foreground` (`ThemePalette.page`),
  bars and cards use `--background`, hairlines `--border`, secondary text
  `--muted-foreground`, and the accent is `--primary`. `ThemeColor` exposes
  these as shape styles; `ThemedForm`/`ThemedList` give grouped settings
  pages raised rows in the theme's colors.
- **Type**: Poppins, the web typeface, is bundled for headings only
  (`DesignSystem/Typography.swift`): navigation bar titles, page, section and
  card titles, scaled with Dynamic Type. Home and Library put their title,
  at large-title size, at the leading edge of the navigation bar on the
  avatar's row, like the web's root headers, and keep it there when content
  scrolls under the bar (the system's inline-large mode would move it to the
  middle); pages pushed on top set their own title mode. Glyphs Poppins
  lacks, such as CJK, cascade to the system fonts for the preferred
  languages at the same weight. Body text, rows and controls keep the
  system font.
- **Components**: shelves of three tiles with a "See more" link, two-column
  grids, compact song rows (about the web's 56pt) without separators and
  with the web's bouncing equalizer for the current song, icon tiles on library and settings rows, bordered
  cards (`cardSurface`) and small uppercase captions for search results and
  the device overview.
- **Detail headers**: album, playlist and artist pages share `DetailHeader`,
  the web image header: the cover (round for artists) over a band of the
  cover's RMS average color, limited to 40% saturation and to at most 30%
  lightness in dark mode or at least 60% in light mode, washed with the theme
  background, which reaches under the navigation bar and fades into the page.
  Header text is white in dark mode and black in light mode, and the bar
  follows the same scheme while the header is visible. Below it, a long Play
  capsule on Liquid Glass sits between bare
  Shuffle and heart (or download) symbols.
- The mini player and Now Playing keep their own presentation. Now
  Playing shares only the type and the web's like color: the song title and
  queue section titles are set in Poppins, and the heart turns red and
  filled while the song is a favorite.

## Platform

| Item | Value |
| --- | --- |
| Minimum OS | iOS 26.0 (iPhone and iPad) |
| Toolchain | Xcode 26, Swift 6.2 compiler, Swift 5 language mode |
| Player sliders | [SliderControl](https://github.com/realtvop/slidercontrol), pinned to a revision in the app target |
| Bundle identifier | `github.realtvop.aonsoku` (unchanged, so upgrades keep data) |
| Background modes | `audio`, `fetch` (BGTask `github.realtvop.aonsoku.sync.refresh`) |

## Layout

```text
ios/
  Aonsoku.xcodeproj      App project. Uses synchronized folders, so adding a
                         Swift file under ios/Aonsoku needs no project edit.
  Aonsoku/               App target: views, navigation, composition root.
    App/                 @main app, AppDelegate, root and tab views.
    DesignSystem/        Router, theme and typography, artwork, rows,
                         shelves, surfaces, detail chrome, marquee, toasts,
                         formatters.
    Features/<Area>/     One folder per screen family: Account, Album,
                         Artist, Devices, Home, Library, Login, Menus,
                         Player (mini player, Now Playing, lyrics, queue),
                         Playlist, Search, Settings, Song.
    Resources/           Asset catalog, Info.plist, Poppins headings.
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

- **Tabs**: Home, Library, Search (`Tab(role: .search)`), each with an
  independent native navigation stack. Search remains separate from the
  other tabs; the system owns minimization on scroll and all transitions.
  `SearchView` owns its text/query state and native `searchable` field with
  default system placement and activation. No forced bottom placement or
  tab-selection search activation is applied. Typing retains the 500ms
  debounce; submitting searches immediately. iPad uses the adaptable sidebar.
- **Mini player**: the system `tabViewBottomAccessory` contains only a
  layout marker; its native glass host is hidden. Its inline/expanded
  presentation-layer geometry, sampled by a passive `UIUpdateLink`, positions
  the actual mini controls inside `NowPlayingPresentation`, the same persistent
  container as the full player, background and cover. Controls, artwork
  and glass follow the native minimization frame with continuous compact
  layout interpolation and no independent animation clock. This
  container owns the sole Liquid Glass surface, which moves and resizes
  into the pill itself; no separate playback pill remains underneath.
  Tapping it slides Now Playing up at the
  full viewport width; it also shows remote playback when controlling
  another device. `NowPlayingPresentation` keeps the player in the tabs'
  view tree. Downward drags start anywhere except the progress and volume
  sliders; scrolled lyrics/queues return to their top first. The cover moves
  with the expanded surface without shrinking while the finger is down.
  Only release into a committed dismissal sends the cover toward the pill.
  At that point the shared container mask morphs into the pill bounds;
  canceling the drag restores the entire expanded container instead.
  Only the cover shares geometry across layouts. Other controls use their
  own layouts at the container's top. The background fades as the container
  moves down and becomes transparent in the pill. Cover and container use
  the same zero-bounce settling animation. The last valid native accessory
  frame survives host recycling to keep the compact destination stable.
  Expansion/collapse captures the expanded artwork frame and viewport before
  animating the host's rendered state. Its layout probes and native List do
  not inherit that animation, and live layout reports cannot retarget the
  captured endpoints until it completes. Completion tokens discard interrupted
  transitions. An offscreen queue cover remains hidden during collapse and
  returns only at the settled mini slot.
  Tapping the handle or the accessibility escape action also collapses it.
  The player surface keeps the system-resolved viewport corner radius on
  rounded screens/windows. On square viewports its corners grow from 0 to
  32pt over the first 96pt of a downward slide, reversing on expansion.
  A stationary full-viewport probe uses public UIKit concentric corner APIs,
  so the moving player's position never changes the measured baseline.
- **Now Playing**: one opaque color blending the cover palette with the dark
  theme background, shared by all pages and pinned queue headers. The queue
  matches the progress bar's width, extends directly to the top of the scrubber,
  hides system scroll materials, and applies a marquee-style edge fade gradient mask
  at its top and bottom. Artwork
  shrinks while paused, marquee title, favorite and more menus, scrubber,
  transport, volume, and a bottom bar for lyrics, AirPlay, Aonsoku devices,
  and the queue. The pinned SliderControl package supplies `.progressLabels`
  (seek on release, elapsed/remaining labels that scale while dragging, and
  an independently sized quality badge in the center slot) and `.volumeIcons`
  (speaker icons, inertia and elastic limits) variants.
  Volume updates are coalesced with an exact trailing value, and both slider
  touch regions remain excluded from the player's dismissal pan.
  Lyrics and queue replace the large artwork with a compact
  header, as in Apple Music. One persistent `PlayerArtwork` in the presentation
  host moves and resizes between the native accessory destination and
  layout-only slots in the main page, lyrics and queue headers. It keeps the
  same large-resolution image reader through every transition, including
  paused scaling and dismissal.
  Page selection and artwork destination share `PlayerPresentationState`.
  Lyrics, queue and metadata layout slots mount before the first switch.
  Leaving the cover moves its title/actions up toward the compact header,
  scales them to 0.85 and fades them out; returning reveals them from 64pt
  below. Compact metadata crossfades in place between Lyrics and Queue,
  moves downward when returning to the cover, and enters 160ms later when
  coming from the cover. Lyrics, queue rows and section headers rise 24pt
  after a 140ms delay with a 380ms zero-bounce spring/fade; outgoing content
  fades downward over 180ms. Queue effects animate individual row/header
  rendering so the native List, artwork marker and viewport stay stationary.
  The content viewport clips these effects above the playback controls.
  Content effects are local: layout, scroll resets and artwork markers never
  inherit a page-wide animation. Playback controls stay fixed, and page
  buttons animate their selected appearance. Hidden content immediately stops
  accepting touches and accessibility focus. Reduce Motion replaces content
  movement with a short fade and keeps the short artwork transition.
  Every queue entry resets to the
  current track at the top, including reopening fullscreen with Queue selected.
  Once settled at that anchor, a downward pan on the current-track row dismisses
  the player and cancels the List pan; other rows still scroll into history.
  Releasing more than 44pt into history automatically moves the entire current
  row below the viewport. Measured leading space supports short histories;
  the panel drives a 380ms cubic ease-in/out with selection feedback through
  the shared haptics setting. Artwork follows the same native offsets. New
  touches cancel the animation, and Reduce Motion settles immediately.
  It prepares the offset and artwork destination before selection and tracks
  its artwork marker while hidden; switching never inserts a new
  List, replaces the metadata layout slots, or delays the cover destination
  by a frame.
- **Home**: other devices' playback as cards, the featured album carousel
  (the web header card: cover beside title, artist and details over its own
  blurred art, advancing every ten seconds unless Reduce Motion or
  VoiceOver is on), pinned items, Recently Played, Most Played, Recently
  Added, Explore. Pinned and album shelves use 160pt covers on phones and
  180pt covers in regular-width layouts, with free horizontal scrolling and
  no tile snapping. The featured carousel retains its page alignment.
  Pull to refresh runs an incremental sync. The avatar opens the account sheet.
- **Library**: Artists, Songs, Albums, Favorites, Genres, Radio (unless
  hidden) and Downloaded as icon-tile rows, followed by the playlists with a
  "See more" link to the full list and a New Playlist button.
- **Detail screens**: album, artist, playlist, genre, album lists by filter,
  artist discography and tracks, song info.
- **Search**: browse genres when idle; while typing, artists, albums and
  songs under the web's small uppercase captions with "See more" links.
- **Account sheet** (the avatar on Home and Library):
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
bash scripts/test-ios-queue-scroll.sh # Queue/history geometry; no Simulator required

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
