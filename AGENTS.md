# AGENTS.md

This file provides guidance to coding agents when working with code in this
repository.

## Project Overview

Aonsoku is a multi-runtime music streaming client for Navidrome/Subsonic
servers. It targets the web, Electron desktop, Capacitor iOS, and a fully
native Android app (Kotlin + Jetpack Compose, no WebView). It supports
synchronized lyrics, radio streaming, Discord RPC, offline library/cache
features, and cross-device coordination with remote control and handoff.

## Architecture Change Hygiene

When changing the architecture, runtime support, data flow, build commands, or
major module ownership, update `AGENTS.md` in the same change. In particular,
keep these sections current when adding or removing platforms, native capabilities,
background services, state stores, sync paths, or test/build commands.

## Commands

```bash
# Development
pnpm run dev              # Web app dev server
pnpm run electron:dev     # Electron desktop dev

# Build
pnpm run build            # Production web build (tsc + vite)
pnpm run build:mobile     # Capacitor (iOS) bundle with automatic fine-grained chunks
pnpm run electron:build   # Electron renderer/main/preload build
pnpm run make             # Create Electron distributable packages
pnpm exec cap sync ios    # Copy the preceding build into the iOS host

# Lint & Format (Biome)
pnpm run lint             # Check only
pnpm run lint:fix         # Auto-fix lint issues
pnpm run lint:format      # Format files

# Tests
pnpm run test:unit        # Vitest unit tests
pnpm run test             # Cypress component tests

# Coordination server
cd coordination-server && cargo fmt --all
cd coordination-server && cargo clippy --all-targets -- -D warnings
cd coordination-server && cargo test
cd coordination-server && cargo run --bin aonsoku-coordination-server

# Cloudflare coordination server (Node.js >= 22)
pnpm --filter @aonsoku/coordination-worker dev
pnpm --filter @aonsoku/coordination-worker check
pnpm --filter @aonsoku/coordination-worker test
pnpm --filter @aonsoku/coordination-worker build # Deployment dry-run, no account needed
pnpm --filter @aonsoku/coordination-worker build:ci # Workers Builds dry-run; preserves dashboard runtime vars
pnpm --filter @aonsoku/coordination-worker deploy:ci # Workers Builds deployment; preserves dashboard runtime vars
pnpm coordination:deploy # Guided login/configuration/key creation/deployment; reuses saved choices
pnpm --filter @aonsoku/coordination-worker test:deploy # Deployment wizard regression tests
pnpm --filter @aonsoku/coordination-worker deploy:raw # Direct Wrangler deployment for operators/CI

# Android native app (Gradle 9 wrapper, JDK 21; no Node/pnpm step required).
# The build reads package.json (version), src/i18n/locales and public/fonts
# straight from the repository.
cd android && ./gradlew :core:compileDebugKotlin     # Native services module
cd android && ./gradlew :core:testDebugUnitTest      # Service unit tests
cd android && ./gradlew :app:testDebugUnitTest       # App unit tests + JVM smoke tests (Robolectric)
cd android && ./gradlew :app:testDebugUnitTest --tests '*AppSmokeTest*' \
  -PsmokeScreenshots=/tmp/aonsoku-shots [-PsmokeTheme=dark]  # Save a PNG of every screen the smoke tests visit
cd android && ./gradlew :app:assembleDebug           # Debug APK
node scripts/android/generate-theme-palettes.mjs     # Regenerate ThemePalettes.kt from src/themes.css

# Android release signing
# Local release builds read aonsokuRelease* from ~/.gradle/gradle.properties.
# Nightly/tag release workflows restore the same keystore from GitHub Secrets.
cd android && ./gradlew assembleRelease

# iOS native plugin. Selects the first available iPhone Simulator; override
# with IOS_SIMULATOR_ID=<uuid>. Fails when no simulator is available, when no
# XCTest executes, or when any test fails. The optional result path must not
# already exist.
./scripts/test-ios-native.sh
IOS_TEST_RESULT_BUNDLE=/tmp/AonsokuNativeTests.xcresult ./scripts/test-ios-native.sh

# iOS native core
cd ios/App && xcodebuild -project App.xcodeproj -scheme App \
  -destination 'generic/platform=iOS Simulator' build

# Electron desktop native audio
pnpm native-audio:build   # Build the Node-API libmpv addon
pnpm native-audio:prepare # Copy addon/runtime libs into resources/native-audio
pnpm native-audio:smoke   # Load libmpv and play a generated WAV fixture
pnpm native-audio:smoke:packaged # Smoke test resources/native-audio layout
pnpm native-audio:verify-package # Check Forge/resource/native-audio packaging
pnpm native-audio:verify-package:strict # Fail if native runtime files are missing
pnpm native-audio:verify-package:linux # Strict verify + ldd/readelf runtime linkage check (Linux host)
# Linux local/release paths also run the packaged smoke check:
# build:linux / make / publish run run-packaged-smoke.mjs --only linux,
# which is a no-op on macOS/Windows. On a Linux host targeting Linux,
# verify-libmpv-package.mjs additionally runs ldd/readelf deep checks
# (no `not found` deps, $ORIGIN rpath on every bundled .so, addon's
# libmpv resolves from the $ORIGIN bundle).
node scripts/native-audio/linux-runtime-linkage.mjs --platform linux # Standalone Linux runtime linkage check
pnpm native-audio:check-glibc-baseline   # Verify Linux glibc baseline consistency across forge config, docs, and CI

# CI helpers used by .github/actions/setup-native-audio
node scripts/native-audio/ci/fetch-libmpv-windows.mjs --arch x64|arm64
node scripts/native-audio/ci/collect-runtime-darwin.mjs --root <libmpv.dylib> --staging <dir> --addon <addon.node>
```

## Architecture

### Multi-Target Build

- **Web**: Vite (`vite.config.ts`) builds `src/` as a standard SPA.
- **Electron**: `electron.vite.config.ts` builds `electron/main`,
  `electron/preload`, and the renderer, which reuses `src/`. A second,
  Electron-only renderer entry `electron/renderer/native-debug/index.html`
  builds the native player debug window (see Multi-Stack Native Playback); it
  is not part of the shared `src/` SPA, so web/Capacitor builds never bundle
  it. `tailwind.config.js` scans `electron/renderer/**` for its utility
  classes, and `tsconfig.electron-renderer.json` type-checks it.
- **Capacitor iOS**: `capacitor.config.ts` points the iOS host at `dist`. The
  custom native plugin lives in `capacitor-plugins/capacitor-native` (TypeScript
  definitions + Swift sources) and is included through pnpm workspace package
  `@aonsoku/capacitor-native`. The package no longer has an Android side.
- **Android (native)**: `android/` is a standalone Gradle project (Kotlin DSL,
  version catalog in `android/gradle/libs.versions.toml`, AGP 9 with built-in
  Kotlin) with two modules. It does not use Capacitor, a WebView, or the web
  bundle. See "Android Native App" below.
  - `android/core` (`:core`, namespace `github.realtvop.aonsoku.plugins`) holds
    the long-lived native services: authentication, preferences, library/Room,
    playback, downloads, scrobbling, and the coordination socket runtime.
  - `android/app` (`:app`, namespace `github.realtvop.aonsoku`) is the Jetpack
    Compose / Material 3 Expressive UI.
- Android `LibraryService`
  (`github.realtvop.aonsoku.plugins.data.LibraryService`) is application
  scoped and owns Room queries, metadata sync, lyrics, and the image cache. It
  exposes typed Kotlin paging/filter/search and `StateFlow`/`SharedFlow` sync
  notifications. UI code calls `LibraryService.getInstance(context)` (or
  `AppServices.library`) directly.
- `PlaybackService` implements the typed Android `AudioService` contract in
  `audio/AudioService.kt`. Its `StateFlow` playback/queue snapshots and
  independent `SharedFlow` event stream are available from
  `PlaybackService.LocalBinder.getAudioService()`; player, MediaSession,
  foreground-service, audio-route, and system-volume resources remain owned by
  `PlaybackService`. It also maps ExoPlayer errors to `AudioEvent.Error`,
  publishes coordination snapshots on playback/queue changes, and forwards
  system-media commands issued during remote projection to the coordination
  port.
- Android queue resolution by song/album/playlist ID, queue edits, handoff
  preparation/rollback, and sleep timers are `AudioService` commands executed
  by `PlaybackService`. Queue commands resolve local songs through
  `LibraryService`, preserve the existing context/user/shuffle/history order,
  and return `AudioCommandResult` errors for missing local data or failed
  handoffs. Playback persistence and scrobble buffering are also owned by
  `PlaybackService`.
- Android offline audio is owned by the application-scoped
  `audio/AudioCacheService` (`AppServices.audioCache`), not by
  `PlaybackService`: the files in the audio cache directories, their index
  (rows of type `audio` in the Room `cacheMeta` table, carrying the source
  `explicit`, `smart`, or `lru` and the smart-download triggers), and the one
  download queue (four at a time; what plays now before the user's downloads
  before smart downloads; a song is never fetched twice at once). It publishes
  `cached` and `downloads` as `StateFlow`s plus `AudioCacheEvent`s. A request
  for a song that is already kept fetches nothing and only changes the owner
  when it outranks what the file was kept for. The user's downloads are
  written to `pending-downloads.json` until they succeed and run again on
  `resume()` after a passing failure; `AudioUnavailableException` (the server
  refused, or sent a Subsonic error document instead of audio) drops them.
  Files without an index row (the Capacitor app kept its index in the
  WebView) are adopted as explicit downloads, the one kind that is never
  removed automatically. `NativeDownloadManager` is only the transfer of one
  song into the cache. `PlaybackService` asks for an `lru` copy of what it
  streams and touches the cached file it plays; it has no download state of
  its own.
- Android authentication and Subsonic HTTP access are owned by the
  application-scoped `bridge/AuthenticationService`. It owns the encrypted
  credential store, login/fallback probing, server discovery, and typed
  requests. `LibraryService`, `PlaybackService`, download/source resolution,
  and native scrobbling use the same authentication service.
- Android preferences are owned by the application-scoped
  `preferences/PreferencesService`, which wraps `NativePreferencesStore` and
  preserves the `pref.` keys, queue-state key, play-history codec, and existing
  serialization. It exposes a shared change flow.
- Android `AppServices` is the application-scoped service graph for
  authentication, preferences, library, the audio cache, and the audio and
  coordination ports.
  `PlaybackService` registers its `AudioService` when created and unregisters
  only itself on destruction; `coordination/CoordinationRuntime` (application
  scoped, `CoordinationRuntime.getInstance(context)`) registers the
  `CoordinationService` port and owns the WebSocket lifecycle. Remote
  commands, native snapshots, projection, handoff preparation, fencing, and
  rollback use these ports. The runtime publishes socket state as a
  `StateFlow` and forwards unconsumed envelopes, tracked command acks, and
  reconnect requests as `CoordinationRuntimeEvent`s.
- Service boundaries and binding/lifecycle rules are documented in
  `docs/android-native-services.md`.
- The iOS host owns long-lived native services through
  `AonsokuNativePlugin.AppServices`. `AudioService` owns AVPlayer, queue,
  downloads, scrobbling, playback persistence, and system media controls;
  direct streams retain background cache downloads and the staged
  `PlaybackRecoveryController` seek/reload fallback inside that service;
  `AonsokuNativeAudioPlugin` is only the Capacitor payload/event adapter. New
  native UI surfaces must call the typed service rather than locating a plugin
  through `CAPBridgeProtocol`. `AudioCommand`, `AudioPlaybackSnapshot`, and
  `AudioQueueSnapshot` are the native command/state contract; SwiftUI clients
  can use `observeState` or `stateUpdates()` without depending on Capacitor.
- `LibraryService` is the public iOS library boundary for native UI. It owns
  GRDB repository access, metadata sync/scheduling, typed library queries, and
  cover/avatar caching through `AppServices.library`; native UI must not open
  `DatabaseManager` or construct repository types directly. The Capacitor data
  plugin reuses this same service and adapts its typed events for the WebView.
- `AppLifecycleService` is the App/Scene lifecycle boundary shared by the iOS
  host and `AppServices`. It starts/restores audio once, flushes playback state
  on background/termination, validates coordination with a foreground ping and
  capped fresh-ticket reconnect requests, and routes background URLSession
  relaunch callbacks to the audio download manager. WebSockets use a normal
  URLSession because iOS background sessions are reserved for transfer tasks;
  downloads use `github.realtvop.aonsoku.audio.downloads` and survive relaunch.
  The Swift package owns `AonsokuNativePluginTests`, which exercises queue and
  shuffle behavior, staged playback recovery and persistence, source/cache and
  download behavior, scrobbling, handoff and coordination contracts, auth and
  HTTP behavior, preferences, event contracts, typed library queries/sync,
  lifecycle transitions, the `AppServices` graph, and Capacitor adapters. The
  tests use injectable AVPlayer, URLSession, time, file-system, database, and
  lifecycle boundaries and do not require real network access. The test script
  parses its `.xcresult` and requires a non-zero executed test count;
  `build-ios.yml` preserves that result bundle before packaging.
- Platform/runtime detection is centralized in `src/utils/capabilities.ts`,
  with lower-level helpers in `src/utils/desktop.ts` and
  `src/utils/platform.ts`.

### State Management

Two complementary systems:

- **Zustand** (`src/store/`) — client state with `immer`, `persist`,
  `devtools`, and `subscribeWithSelector` middleware. The player store is now
  modularized under `src/store/player/`; `src/store/player.store.ts` is mainly
  a compatibility export surface.
- **TanStack React Query** (`src/queries/`) — server/native data reads,
  caching, and invalidation. Query client configuration lives in
  `src/lib/queryClient.ts` with refetch-on-window-focus disabled.

Persistent browser-side library/cache data uses Dexie in `src/store/library-db.ts`
and IndexedDB helpers in `src/store/idb.ts`. Offline-capable UI paths generally
go through `src/lib/offlineQueryClient.ts`, which tries IDB/native data before
network when an offline function is available.

Playback state restore is owned by the runtime that owns playback. When the
native playback backend is active (`shouldUseNativePlaybackBackend()`, i.e.
Capacitor iOS/Android or Electron with the desktop native-audio bridge), the
native layer is the single source of truth for the restored queue and progress:
`src/store/player/persistence.ts` skips the renderer-side IDB songlist rehydrate
so `syncFromNative()` (`src/player/queue-controller/native-controller.ts`) sees an
empty renderer songlist, takes the cold-start branch, sets
`nativeDrivenTransition`, and the `AudioSrcChange` effect in
`src/app/components/player/audio.tsx` skips re-issuing `load()`. The Electron
main process restores position itself in
`electron/main/native/audio/service.ts` `#restorePlaybackState()` (persisted via
`playback-state.json`). libmpv receives restored/handoff progress through the
per-file `loadfile` start option, because its asynchronous load command returns
before the new source can accept a seek. Desktop writes are coordinated asynchronously outside
the playback-command FIFO: full-state changes use a 500ms debounce, progress
uses a 5s/meaningful-change throttle, and the store serializes atomic temporary
file replacements so older writes cannot overwrite newer state. Clear cancels
pending work before removing the file, while queue-transaction rollback and
service/app shutdown flush the latest snapshot; persistence failures remain
isolated from playback. The desktop singleton defers restore until
`setupDesktopNativeAudioIpc()` installs its stream/download/artwork resolvers
and calls the service's idempotent `ready()` lifecycle, so a restored uncached
`aonsoku-media://stream` source is translated before libmpv loads it. The
web/Electron-fallback path still rehydrates the songlist from IDB and drives
`load()` + `pendingResumePosition` from the renderer.

### Sync Architecture

Metadata/library sync is runtime-specific:

- **Web**: `src/service/cache/sync-worker-adapter.ts` creates
  `src/service/cache/sync.worker.ts` and communicates with it via Comlink.
  The worker owns its own Dexie instance, receives auth via
  `initAuth`/`updateAuth`, and bridges sync state/query invalidation back to
  the main thread.
- **Worker fallback**: if Web Workers are unavailable, sync falls back to
  `src/service/cache/metadata-sync.ts` on the main thread.
- **Electron, Capacitor iOS**: sync uses
  `src/native/data/native-sync-adapter.ts` and the runtime's
  `AonsokuNativeData` implementation. Electron implements the bridge in
  `electron/main/native/data/`; iOS uses the Capacitor plugin. Native
  runtimes do not fall back to the browser Worker/IndexedDB sync path.
- **Android (native)**: the Compose app drives `LibraryService` (Room +
  `SyncEngine`) directly; no TypeScript is involved.

### Data Flow

```text
Subsonic/Navidrome server
  -> src/api/httpClient.ts / src/api/nativeHttpClient.ts
  -> src/service/*.ts or src/native/* facades
  -> src/queries/*.ts and src/lib/offlineQueryClient.ts
  -> React components
```

For native runtimes, album/song search and list queries may read through
`AonsokuNativeData` instead of directly calling Subsonic services. When changing
library data behavior, check the online service path, IDB/offline path, and
native data facade.

Electron follows the same renderer/native ownership boundary as Capacitor:

- Renderer code calls the shared native bridge, data, audio, and coordination
  facades. It must not open Subsonic/coordination HTTP or WebSocket connections.
- `electron/main/native/bridge/` owns credentials, login, server probing, and
  generic Subsonic requests.
- `electron/main/native/data/` owns metadata sync, persistent library queries,
  lyrics metadata, and cover/avatar downloads. Its `syncAll` and
  `syncIncremental` paths honor `includeCoverArt`, `coverArtConcurrency`, and
  `useAlbumCoverForSongs`, downloading the required cover IDs into the main
  process `CoverCache`.
- `electron/main/native/preferences/` owns Electron desktop preference
  persistence exposed through `AonsokuNativePreferences`; renderer-side
  Zustand/UI preference stores should use `src/store/native-storage.ts` instead
  of adding new Electron renderer `localStorage` persistence.
- `electron/main/native/coordination/` owns coordination HTTP, token/config
  persistence, and the realtime WebSocket.
- `electron/main/native/media-protocol.ts` resolves renderer-facing
  `aonsoku-media://` cover/avatar/stream identifiers and injects credentials in
  the main process. Renderer code must not construct authenticated server URLs.
  The image proxy (`getCoverArt`/`getAvatar`) is bounded by a main-process
  `AsyncLimiter` (`electron/main/native/concurrency.ts`, concurrency 6), serves
  disk-cached covers first via `DesktopNativeDataService.readCoverWithMeta`
  (skipping the network when the cached copy is at least the requested size),
  and applies a 15s stall timeout (`AbortSignal.any([request.signal,
  AbortSignal.timeout(15_000)])`). `stream` stays on Node's default global
  `fetch` (no body timeout, so buffered-playout backpressure never aborts it);
  it is separated from the image flood because images/metadata no longer use
  the default agent. Bridge `downloadBinary`/`performRequest` and the
  `media-protocol` image proxy go through a dedicated undici `Agent`
  (`electron/main/native/bridge/http-agent.ts`, 16 connections per origin,
  `headersTimeout`/`bodyTimeout` set) via `subsonicFetch`, so image and
  metadata traffic shares one raised connection ceiling instead of saturating
  Node's default low-limit global pool and starving IPC handlers.

### Cross-Device Coordination

Aonsoku includes a Rust coordination service in `coordination-server/` for
device registration, presence, playback snapshots, remote control, history
sync, and handoff. An alternative TypeScript Cloudflare deployment lives in
`coordination-worker/`
(workspace `@aonsoku/coordination-worker`). It implements the same `/v1/*` and
version-1 WebSocket client protocol with one SQLite-backed Durable Object per
account. WebSocket attachments preserve connection/control state through
hibernation; SQLite owns history, snapshots, pending ACK routes and handoff
transactions. Alarms handle deadlines and cleanup. It requires a stable secret
and an operator-trusted exact HTTPS origin allowlist for Navidrome verification
(all redirects rejected), rather than Rust's arbitrary-host DNS/IP-pinning
policy. Rust and Workers have separate databases/credentials; switching URLs
requires device registration, not automatic data migration. See
`coordination-worker/README.md` for deployment and local Miniflare integration
tests; `.github/workflows/coordination-worker.yml` checks this runtime on Node 22.
The Deploy to Cloudflare button targets the generated `coordination-worker`
branch, whose root contains only the self-contained Worker. This keeps the main
app's root `.env.example` out of the button's secret scan. The branch is rebuilt
by `.github/workflows/coordination-worker-branch.yml` whenever the Worker source
changes. Full-repository Cloudflare Workers Builds remain available for GitHub
forks that need the daily upstream-sync workflow. Their `build:ci` / `deploy:ci`
commands use `coordination-worker/wrangler.ci.jsonc`, which declares the
binding/migration config without runtime vars. Runtime settings/key are set in
the dashboard and preserved by Wrangler `keep_vars`; ordinary Wrangler configs
declare defaults that overwrite same-named dashboard vars.
`coordination-worker/ONLINE-DEPLOY.md` documents both setup paths. The Worker
keeps a local copy of the protocol types
in `coordination-worker/src/protocol.ts` so its deployment has no dependency
outside its source tree.
`.github/workflows/coordination-upstream-sync.yml` optionally syncs direct forks
daily via GitHub's merge-upstream API when repository variable
`COORDINATION_AUTO_SYNC=true`; no force push or personal token is used.

The client-side orchestration lives in `src/coordination/`
with React state in `src/coordination/store.ts`.

Player and fullscreen handoff UI subscribe through
`CoordinationManager.subscribeHandoffEvents()`. These independent subscriptions
survive observer reconnects and unsubscribe without replacing other UI handlers;
do not stack and restore mutable completion callbacks in component effects.

Mobile handoff restores context/user queues and previous user songs without
reshuffling the transferred order. Candidate preparation suppresses snapshots;
failure or disconnect restores the preceding local queue. Native commit events
reach the UI after queue preparation completes. The compact mobile player owns
the device drawer outside fullscreen, so home-page device links also work before
local playback begins; fullscreen owns its own drawer while open.

- Web uses the TypeScript WebSocket client (`src/coordination/wsClient.ts`).
- Electron, iOS, and Android use `src/native/coordination/facade.ts` and their
  runtime-native coordination implementations.
- Electron native playback coordination is executed by
  `electron/main/native/coordination/playback.ts`: it publishes native queue
  snapshots, executes and acknowledges remote commands, prepares full queues
  paused before `target_ready`, relinquishes through the audio FIFO, and adopts
  the committed session/generation. Coordination session state is persisted in
  the main-process coordination store. Disconnect stops publication; shutdown
  tears down coordination before the audio service. When native playback is
  unavailable, Electron keeps native networking but the renderer observer owns
  Web Audio playback orchestration. Native handoff completion is forwarded to
  the facade for UI status, without executing playback again in the renderer.
- The native facade retains its listeners across reconnects and retries fresh
  WebSocket tickets with exponential backoff capped at 30 seconds, including
  when the network is unavailable before the native socket can be opened.
  Manual disconnect cancels retries.
- The root app mounts `CoordinationObserver`, and player/fullscreen/lyrics
  surfaces can project remote playback through
  `src/app/components/remote-control/`.

When changing playback controls, queue semantics, lyrics timing, scrobbling, or
handoff behavior, check local playback, remote-control projection, and native
coordination behavior together.

Queue replacement confirmation is owned by the shared player actions in
`src/store/player/queue-actions.ts`, before local native-controller dispatch or
remote command submission. It protects remaining manually added `userQueue`
songs (excluding the current song while `isInUserQueue`), not the album/playlist
`contextQueue`. Paused playback, current-song/context resume, queue navigation,
and queue additions do not prompt. Remote confirmation reads the controlled
device's coordination snapshot rather than the preserved local queue; pending
dialogs are bound to that device and canceled when the playback target changes.
Remote Play Next and Add to Queue map to the existing `add_to_queue_next` and
`add_to_queue_last` protocol commands, using the exact selected song IDs. Native
receivers execute already-confirmed remote commands without another dialog.

### Routing

React Router v6 uses hash routing (data router via `createHashRouter` in
`src/routes/router.tsx`). Route constants live in
`src/routes/routesList.ts`. Auth is enforced via loaders
(`protectedLoader.ts`, `loginLoader.ts`) — always use named route constants from
`ROUTES` rather than hardcoded strings.

The base layout's page outlet (`src/app/layout/main.tsx`) uses
`KeepAliveOutlet` (`src/app/layout/keep-alive-outlet.tsx`) instead of a plain
`<Outlet />`. Previously-visited route subtrees are kept mounted but hidden
(`display: none`) and toggled back to `display: contents` when revisited, so
returning to a page (especially the pinned home page) instantly shows the
already-loaded cover-art images and preserved component state instead of
re-fetching/re-mounting. To keep cached pages correct while hidden, each cached
subtree is re-wrapped in a frozen `UNSAFE_LocationContext.Provider` holding the
location it had when last active; the per-route `RouteContext` (params/matches)
is already embedded in the element returned by `useOutlet()`. Freezing only
`LocationContext` is sufficient because no cached page subtree reads volatile
global data-router state (`useMatches`/`useNavigation`/`useNavigationType` are
only used outside the cached outlet, e.g. in the header). Scroll position is
saved per cached route and restored on return; fresh pages scroll to the top
(this replaces the old route-change `scrollPageToTop` effect in `main.tsx`).
`KeepAliveOutlet` is configured with `exclude={["error"]}` and `pin={["home"]}`
and an LRU cap; when adding new routes that must always remount, add their id to
`exclude`, and avoid `useSearchParams`/`useLocation`/`useMatch` reading the live
location from inside a cached subtree unless the freeze above is extended.

### Component Patterns

- Radix UI primitives + shadcn/ui copy-paste pattern (full ownership of
  component code).
- `src/app/components/` — reusable UI components.
- `src/app/pages/` — route-level page components.
- `src/app/tables/` — data table implementations.
- Root observers live in `src/app/observers/` and are mounted in `App.tsx`.
  They include theme/lang/media session, native auth/remote commands, Android
  back button handling, metadata sync, coordination, network monitoring, and
  smart downloads.

### Styling

Tailwind CSS uses CSS custom properties for layout dimensions
(`--header-height`, `--sidebar-width`, `--player-height`, safe-area variables,
etc.). Theme variables (HSL colors for dark/light) are in `src/themes.css`.
Dark mode is class-based.

### Code Splitting

Normal Web (`pnpm run build`) and Electron renderer builds use
`manual-chunks.ts` to preserve the established larger `pages`, `core-vendor`,
and `heavy-vendor` bundles. Capacitor builds use `pnpm run build:mobile`
(`vite --mode mobile`), which leaves chunk ownership to Rollup so lazy modules
stay separate instead of collapsing every page and dependency into startup
chunks. iOS CI and release workflows must use `build:mobile` before
`cap sync ios`; do not use the normal Web build for a native package. The
Android app is native and never consumes the web bundle.

The HTML boot shell and its inline styles load without the application
stylesheet; `src/main.tsx` restores native preferences before dynamically
importing `src/render-app.tsx`, which owns the application styles and React
tree. When adding large dependencies or moving substantial lazy-loaded feature
areas, verify both build modes: the normal Web output should retain the named
large chunks, while the mobile `dist/index.html` should not preload optional
route chunks or application CSS.

## Tooling Notes

- **Package manager**: pnpm only.
- **Workspace**: root app, `packages/*`, `capacitor-plugins/*`, and
  `coordination-worker` (Cloudflare service; Node.js >= 22).
- **Linter/formatter**: Biome 2.0.6 — double quotes, trailing commas,
  80-character line width, no unused vars/imports.
- **TypeScript**: strict mode, path alias `@/` -> `src/`.
- **Rust**: coordination server is a separate Cargo project under
  `coordination-server/`.
- **Native**: the native Android app lives under `android/` (`:core` services
  + `:app` Compose UI); the iOS host lives under `ios/`; the Capacitor plugin
  (TypeScript definitions + iOS Swift sources) lives under
  `capacitor-plugins/capacitor-native/`.
- **Git hooks**: Husky is configured (`.husky/`) and pre-commit runs
  `pnpm lint`.

## Android Native App

The Android app is written in Kotlin with Jetpack Compose and Material 3
Expressive. It replaces the former Capacitor Android host; `capacitor-android`
is no longer a runtime that ships, although the shared web code may still
contain `capacitor-android` branches used for capability typing.

- Toolchain: Gradle wrapper 9.x, AGP 9 (built-in Kotlin — do not apply
  `org.jetbrains.kotlin.android`), Kotlin/Compose compiler plugin and KSP
  versions pinned in `android/gradle/libs.versions.toml`, `compileSdk` 37,
  `minSdk` 24, JDK 21. Build scripts are Kotlin DSL.
- `android/app/build.gradle.kts` reads the product version from the root
  `package.json` (`BuildConfig.APP_VERSION`), and its
  `syncAonsokuSharedAssets` task packages `src/i18n/locales/*.json` as
  `assets/i18n/` and the Poppins weights from `public/fonts` as
  `assets/fonts/`. Translations therefore have one source of truth; add or
  change strings in `src/i18n/locales`.
- `versionCode`/`versionName` in `android/app/build.gradle.kts` are rewritten
  by `capacitor-set-version` in `create-tag.yml`; keep exactly one occurrence
  of each name in that file.
- Existing installs upgrade in place: the application id, encrypted
  credential store, DataStore preferences (`pref.*`, `queue_state`), Room
  library database, and audio/image cache directories are unchanged.

App module layout (`android/app/src/main/java/github/realtvop/aonsoku/`):

- `AppGraph` is the application-scoped object graph (manual DI) created by
  `AonsokuApplication`; it wraps `AppServices` from `:core` and is exposed to
  composables through `LocalAppGraph`. It loads settings and restores the
  session before the first frame.
- `settings/`: `AppSettings` is the single serializable preferences document,
  stored by `SettingsRepository` under the `native_app_settings` key of
  `PreferencesService`. On the first native launch
  `LegacySettingsImporter` seeds it from the zustand documents the former
  WebView app persisted (`theme_store`, `lang_store`, `player_store`,
  `app_store`, `cache_settings`, `pinned_home_store`, `player_history`).
- `i18n/`: `I18n` loads the packaged locale JSON at runtime and resolves
  dotted keys, `{{name}}` interpolation, CLDR plural suffixes, and dayjs-style
  relative time, with English as fallback. Use `t("key")` / `plural(...)` in
  composables; never hardcode user-facing strings.
- `theme/`: `ThemePalettes.kt` is generated from `src/themes.css` (20 web
  themes); `ColorSchemes.kt` maps the web tokens onto Material 3 roles and
  `AonsokuTheme` applies `MaterialExpressiveTheme` with the expressive motion
  scheme, Poppins typography, light/dark/system mode, per-mode theme choice,
  and Material You dynamic color on Android 12+.
- `session/SessionManager` owns sign-in state on top of
  `AuthenticationService`: login with protocol-version check, primary/fallback
  server selection, and logout.
- `data/`: `api/SubsonicApi` is the typed OkHttp client for the UI layer; it
  signs requests with the credentials owned by `AuthenticationService`, so the
  UI, playback, and sync share one identity. `LibraryRepository` is the single
  read/write entry point for screens: lists read the Room library through the
  typed, parameterized `LibraryService.queryAlbums/querySongs/queryArtists`
  (`LibraryQueries.kt`; the legacy DAO `getFiltered` sort expressions never
  sorted) and fall back to the server while the library is empty; detail
  pages emit the local copy first and then the server copy (`Loadable`), and
  everything read online is written through to Room. Server-ordered album
  lists (recently/most played) prefer the server when online.
  `NetworkMonitor` defines "online" as an authenticated ping to a configured
  URL succeeding (plus metered detection); `LibrarySyncCoordinator` runs the
  startup sync and the throttled foreground incremental sync.
- `data/image/`: artwork is loaded by Coil through `CoverArtFetcher`, which
  resolves `CoverArt`/`AvatarArt` models to files in the native image cache
  (`ArtworkStore` → `LibraryService.resolveCoverImage`/`downloadCoverImage`,
  one 700px copy per cover id, bounded parallel downloads). The loader is
  configured in one place, `artworkImageLoader`, used by `AonsokuApplication`
  and by the smoke tests. Screens use `CoverImage`; never build authenticated
  image URLs in UI code.
- `data/lyrics/`: `LyricsRepository` (`AppGraph.lyrics`) finds the lyrics of a
  song the way the web player does. OpenSubsonic structured lyrics
  (`getLyricsBySongId`) come from the Room `lyrics` table or the server and
  are written back to Room, so a song keeps them offline once they were
  shown. Lyrics as text come from the sources in the order of
  `LyricsSettings.sourcePriority`: the music server (`getLyrics`), LRCLIB
  (`LyricsSources`, off when `lrcLibEnabled` is false, single artist for
  LMS), and a custom lyrics server (JSON entries or plain text, optional
  `Authorization` value). Answers are cached per song and settings by
  `LyricsStore` under the cache directory; lookups that found nothing are not
  repeated for five minutes. `LyricsParser` is the pure part: LRC (several
  timestamps per line, inline translations as a second line with the same
  timestamp, a romanization track matched by timestamp), structured tracks
  (the second track is the translation), and the order of preference when
  resolving what to show (`resolve`: synced structured, unsynced structured,
  LRC text, plain text). Per-song choices live in
  `LyricsSettings.selected`, keyed by `LyricsSong.key` (path, artist, title,
  album, the key the web app used): the chosen custom-server entry, whose
  lyrics `LyricsStore` keeps under the files directory, a timing offset, or
  lyrics turned off. Only the newest `MAX_CHOICES` are kept. As on the web, a
  chosen entry is served by the custom source in its turn, so it does not
  override a source placed before it. `revision` changes whenever a choice
  may have changed what `load` returns.
- `player/`: `PlayerController` is the only UI-facing owner of playback. It
  binds `PlaybackService`, mirrors its `StateFlow` snapshots into
  `PlayerState`/`PlaybackProgress`, and turns user intent into
  `AudioCommand`s. The queue rules of the web player live here and in the
  pure `QueuePlanner`: the context queue always starts at the current song
  (earlier songs are dropped, or rotated to the end with repeat-all),
  shuffle/repeat changes rebuild it from the remembered source list, and
  starting something new asks first (`pendingReplacement` →
  `QueueReplacementDialog`) when it would discard manually queued songs while
  playing. It also records play history (songs played ≥ 10s, stored through
  `PreferencesService` play history), owns like toggling for the current song
  (server + Room, mirrored to the notification via
  `AudioService.setLikeActive`), pushes ReplayGain settings to the service,
  and handles the `RemoteCommand`s the service cannot complete itself
  (`like`, `shuffle`). It mirrors the service's sleep timer as
  `sleepTimer` (`startSleepTimer`, end of track, cancel), and `playNow`
  starts one song (a history entry) without discarding what is queued.
  Screens call `PlayerController`; they never talk to `PlaybackService`
  directly.
- `ui/`: `AonsokuApp` is the root composable (theme, strings, session gate,
  toasts). Toasts (`Toaster` / `ToastHost`) show at the top of the screen like
  the web app's, a newer one replaces the one on screen, and a tap dismisses
  one. `ui/shell/MainShell` hosts the type-safe Navigation Compose graph
  (`ui/navigation/Routes.kt`) with one back stack per top-level tab and the
  floating navigation bar (`FloatingNavBar`: Home/Library pill plus a detached
  Search button), with the floating `ui/player/MiniPlayer` above it once
  something is loaded. Scrolling pages add `LocalFloatingBarsPadding` to
  their content padding.
- `ui/player/`: tapping `MiniPlayer` opens `FullscreenPlayer`, a sheet that
  `MainShell` draws over the pages and the floating bars. It slides up,
  follows a downward drag, closes on back, and while it is open the content
  below is removed from the semantics tree. `FullscreenPlayerState`
  (remembered by `MainShell`) holds whether it is open and its `PlayerTab`;
  add a tab there rather than opening a second surface. The sheet is tinted
  with the artwork (`PlayerPalette.kt`: the backdrop mixes the cover's
  average color into the theme background by the `songColorIntensity`
  setting, and `PlayerPalette` picks content colors that contrast with it;
  composables inside read `LocalPlayerPalette` instead of the theme's
  on-colors), and it reports through `LocalSystemBarsOverride` whether the
  system bar icons must be light or dark. `PlayingView` is the
  artwork/progress/transport/volume view built from `PlayerControls.kt`.
  `rememberPlayerLyrics` loads the lyrics of the current song while the
  player is open and reloads them when a lyric setting, the choice for the
  song, or the reachability of the server changes; the lyrics tab button is
  only disabled once it is known that there are none. `LyricsView` shows
  synced lyrics that follow a frame clock interpolated between the service's
  position reports (active line lit and resting near the top, others dimmed
  and, on Android 12+, blurred; a tap seeks; scrolling by hand hides the
  controls and pauses following for a few seconds) or plain lyrics;
  `LyricsSettingsView` is the per-song page (lyrics off, offset, custom-server
  search and entries).
  `QueueView` shows the play history above the current song (out of sight
  until scrolled to), then the manually queued songs and the context queue,
  with drag-to-reorder inside a section (`ui/components/Reorder.kt`, which
  restricts a drag to the rows `canMove` allows) and a menu per row.
  `AppNavigator.onOpen` runs whenever a page is requested and closes the
  player, so a link followed from one of its menus is not hidden behind it.
- Screens: each page is a `@Composable XScreen()` registered in
  `ui/navigation/AppDestinations.kt` and backed by a `ViewModel` obtained
  with `graphViewModel { XViewModel(it) }` (`ui/components/GraphViewModel.kt`),
  which builds it from `AppGraph` and scopes it to the navigation entry, so
  page state survives while the page stays on a back stack. View models read
  through `LibraryRepository`; `LoadableSource` wraps its cached-then-fresh
  `Loadable` flows, and pages reload on `LibraryRepository.changes`
  (`LibraryChange`) and when `NetworkMonitor` reports the server reachable
  again. `AppNavigator.open(route)` pushes a page unless that exact route is
  already on top; do not use `launchSingleTop` for it, which would replace an
  album page with another album in place and reuse its view model. Wrap
  suspending loads in `runSuspendCatching` (`data/RunSuspendCatching.kt`),
  never `runCatching`: the latter swallows the cancellation of a superseded
  load, which then publishes its empty result over the fresh one.
  - `ui/home` (carousel, pinned items, album sections), `ui/library`
    (library root with playlists, albums with filters, artists, songs,
    radios), `ui/search`, and `ui/detail` (album, artist, playlist,
    favorites).
  - Detail pages share `DetailPage` + `DetailHeader`/`DetailActions`
    (`ui/detail/`): the header is tinted with the artwork's average color
    (`DetailHeaderState.accent`), and the page bar (`SubPageTopBar`) turns
    solid and titled once the header title has scrolled under it.
  - Lazy list keys must be unique: lists that may repeat a song (album
    tracks, playlists, favorites) key by index + id, and id-keyed lists are
    de-duplicated before they reach a lazy layout.
- `ui/settings/`: `SettingsScreen` shows the list of settings pages, or the
  page `SettingsRoute.page` names (`SettingsCategory`: server, appearance,
  language, audio, content, privacy, storage; opened from the account sheet in
  `ui/shell/UserSheet.kt`, which also opens `AboutDialog`). Pages are built
  from `SettingsComponents.kt` (`SettingsPage` with `settingsSection` groups
  of `SwitchSetting`, `SliderSetting`, `ChoiceSetting`, `FieldSetting`,
  `ValueSetting` rows) and write straight to `SettingsRepository`; whatever
  consumes a setting observes it, so a page never calls into a service. A
  section is declared outside composition, so its title is resolved with
  `LocalStrings.current.t(...)` rather than `t(...)`. Text fields commit when
  they lose the focus or on the keyboard's done action. Short reorderable
  lists inside a page (the lyric source priority) use
  `ui/components/ReorderableColumn.kt`. Web settings that have no meaning
  natively (automatic fullscreen, pointer cursors, browser picture-in-picture)
  are left out. The storage page (`StorageSettings.kt`) shows the pools from
  `OfflineManager.pools`, asks before it clears one, and opens
  `CacheManagerPage` (`SettingsRoute("storage-items")`), which lists every
  entry of the cache index by name. Library caching cannot be switched off
  natively: the Room library is what every list reads.
- `data/offline/OfflineManager` (`AppGraph.offline`) decides what is kept on
  the device and is the app's only caller of `AudioCacheService`: the user's
  downloads of songs, albums, playlists, and artists (the songs are written to
  Room first so they can be listed offline, and a downloaded song brings its
  lyrics and cover along); smart downloads (`SmartDownloads.wanted` in
  `OfflineRules.kt`: favorite songs and favorite playlists, evaluated again
  when the rules, the favorites, the playlists, the synced library, or the
  connection change, and never on a metered connection); the playback-cache
  and image quotas of `AppSettings.cache`; marking cached songs the synced
  library no longer lists (`missingFromLibrary`); and the cover-art sync that
  follows a library sync when the setting asks for it. Signing out clears the
  downloads and images together with the library. Song rows and queue rows
  show `ui/components/CachedIndicator`; menus use `DownloadAction` in
  `ui/overlays/Menus.kt`. `ui/shell/SyncStatus.kt` holds the sync tiers, the
  mark on the account picture (`syncBadge`), and the `SyncSection` of the
  account sheet, whose "Sync Now" runs a full sync (the one on the storage
  page is incremental). Downloads run in the app process without a foreground
  service: they stop with the process, and the user's own resume at the next
  start.
- `actions/LibraryActions` (`AppGraph.actions`) holds the library operations
  shared by menus, cards, and pages: resolving the songs of an
  album/artist/playlist for play / play next / add to queue, starring,
  playlist and radio edits with their toasts, and pinning to the home page.
  Starring is optimistic (`LibraryRepository.setStarred` keeps an override
  until the server answers).
- `ui/overlays/`: context menus, forms, and confirmations are not owned by
  the page that opens them. A page calls
  `LocalOverlays.current.show(Overlay.X(...))`; `OverlayHost` in `MainShell`
  renders the one current `Overlay` (song/album/artist/playlist/radio menus
  as modal bottom sheets built with `ui/components/ActionSheet.kt`, add to
  playlist, playlist and radio forms, delete confirmations, song info, the
  zoomable `ArtworkViewer`, and the player's sheets in `PlayerMenus.kt`:
  current-song menu, sleep timer, and color intensity). Add new menus as
  `Overlay` subtypes rather than page-local sheet state. An `ActionSheet`
  item runs after the sheet has closed, so resolve what it acts on (a queue
  index, for example) at that moment rather than when the sheet opened.

App tests (`android/app/src/test`) are JVM unit tests. Besides the pure
logic tests, `smoke/AppSmokeTest` runs the real app on Robolectric: the real
`AppGraph`, native services, Room, DataStore, credential store, HTTP clients,
and the Compose UI, against `smoke/FakeSubsonicServer` (an in-process
MockWebServer with a fixed library). It signs in, lets the library sync, and
walks through the pages, so a page that crashes while composing, loading, or
navigating fails the build without a device. `smoke/SmokeWorld` builds that
world per test: it installs `FakeAndroidKeyStore`, resets the process-wide
`:core` singletons listed in `SmokeWorld.SINGLETONS` (add new ones there),
runs the real `PlaybackService` in-process and hands its binder to
`PlayerController`, and offers `waitUntil`, which runs main-thread and delayed
work while background threads make progress. The shadowed audio output plays
as fast as data arrives, so the fake server throttles `stream`: assert on the
current song and the queue, not on `isPlaying`. Lazy pages only compose what
is visible, so tests scroll to what they assert. Add a journey there when
adding a screen.

The same journeys double as a way to look at the UI without a device:
`snapshot("name")` calls in `AppSmokeTest` save a PNG per screen when the run
passes `-PsmokeScreenshots=<directory>` (`smoke/SmokeScreenshots`, which draws
sheets and dialogs over the activity they cover), and `-PsmokeTheme=dark`
takes them in the dark theme. The fake server answers `getCoverArt` with a
colored square per id, so artwork tinting shows up too, and it stands in for
LRCLIB and a custom lyrics server (`SmokeWorld` passes its address to
`AppGraph(lrcLibUrl = …)`; nothing a test does may reach the internet).
`smoke/LyricsRepositoryTest` and `smoke/OfflineManagerTest` use the same
world without a UI. For downloads the fake server has `throttleStreams`
(switch it off, or a download takes as long as playing the song),
`failStreams`, and `starredPlaylists`, and `SmokeWorld.metered(...)` sets
whether the shadow network is metered (unmetered unless a test says so;
Robolectric's own default counts as metered, which holds smart downloads and
automatic syncs back). Two things
differ from a device there: the test image loader decodes with `BitmapFactory`
and does not crossfade (Robolectric has no `ImageDecoder`, and a fade would be
caught half-way), and the screen size is the one in the test's `@Config` (the
journeys assume that phone size). Review layout changes this way before asking
for a device run.

`AudioService` additions made for the native UI (all executed by
`PlaybackService`): `PlayRadio` (internet radio as a queue-less live stream;
`AudioPlaybackSnapshot.radioId` marks it), `ClearPlayback`, `PlayUserQueueAt`
and `ReorderUserQueue`, `setLikeActive`, `getSleepTimerMode`, and
`setReplayGain` (`ReplayGainCalculator` turns the song's stored ReplayGain
tags into a player volume). Queue snapshots are now also published when the
context queue, repeat mode, or shuffle flag changes, and an ExoPlayer failure
is reported as `AudioEvent.Error` with state `failed`.

## Commit Message Format

`<type>(<scope>): <subject>`

- **type** (required): feat, fix, refactor, test, chore, i18n
- **scope** (optional): a parenthesized area of the codebase, e.g. (queue),
  (cache), (i18n), (fullscreen), (settings), (header), (user-dropdown)
- **subject**: a concise, lowercase imperative description without a trailing
  period. For fix commits, it often explains the problem solved; for feat, what
  was added.

Examples:

- feat(cache): add global AudioCacheQueue with priority scheduling
- fix: robust service worker update detection
- refactor(user-dropdown): reorder menu and remove sync controls
- test: add and improve vitest tests for sync/cache modules
- chore: bump to v0.30.0

The scope is omitted when the change is cross-cutting or does not fit a
specific area. This follows the Conventional Commits convention.

## Multi-Stack Native Playback

The project implements a unified playback abstraction layer (`PlaybackBackend`
interface) supporting multiple playback stacks:

| Stack | Runtime | Implementation |
|---|---|---|
| Web Audio (HTMLAudioElement) | web, electron | `src/player/playback/web-backend.ts` |
| Native audio (Capacitor plugin) | capacitor-ios | `src/player/playback/native-backend.ts` |
| Android native app (no TS) | android | `android/core` `PlaybackService` / `AudioService` |
| Desktop native audio bridge | electron | `electron/preload/native-audio.ts` + `electron/main/native/audio/` |

Key files:

- `src/player/playback/types.ts` — unified `PlaybackBackend` interface.
- `src/player/playback/backend-factory.ts` — platform-aware backend selection.
- `src/native/audio/` — native audio facade and shared TS types.
- `electron/preload/native-audio.ts` and `electron/main/native/audio/` —
  desktop bridge IPC plus a minimal Node.js `NativeAudioService`
  implementing the base `@aonsoku/audio-contract` playback methods through an
  embedded libmpv backend. `engine-factory.ts` creates `LibMpvAudioEngine`
  through the `MpvPlayer` boundary and the Node-API addon in
  `electron/main/native/audio/libmpv/`. The legacy
  `electron/main/native-audio/` path re-exports the new implementation for
  compatibility. Desktop native playback requires the libmpv addon and dynamic
  library to be available; production packages place them under
  `resources/native-audio/<platform>-<arch>/` with a manifest generated by
  `pnpm native-audio:prepare`. `libmpv-binding.ts` validates packaged
  manifests, uses `process.resourcesPath` in packaged apps, and falls back to
  the source build path for development. During Electron development, the
  source build is preferred over a stale `resources/native-audio` copy;
  packaged apps keep the packaged resource first. Missing native pieces
  produce startup diagnostics and visible `error` events while cache/download
  APIs remain usable. Before the renderer selects native playback, a
  synchronous Electron capability handshake confirms that the binding loaded,
  a throwaway `mpv_initialize` succeeds without registering system commands,
  and the addon exposes the required system-media update/clear methods; a
  failed or missing handshake keeps Web Audio, renderer Media Session, and the
  web queue controller active. This is a binding-capability check, not proof
  that an OS media surface is currently healthy. `make`, `publish`, and
  platform package scripts run strict native audio verification and fail if
  addon/runtime files are missing; development
  `build:unpack` runs the non-strict verifier. The Electron service includes a
  desktop queue engine aligned with the mobile native plugin contract for
  context/user queues, shuffle/repeat, full-state export, scrobble buffering,
  sleep timers, remote playback projection, and a platform-scoped system
  adapter for HUD/like integration. `NativeAudioService` serializes all
  playback and queue mutations through one FIFO shared by renderer IPC,
  system-media commands, playback-ended advancement, sleep timers, and state
  restore; queue-driven nested loads use private non-enqueuing helpers to avoid
  deadlocks. Asynchronous engine failures join the same FIFO, settle buffering,
  playback, scrobble, persistence, and renderer state once per service load
  generation, and stale queued failures are ignored after a newer load begins.
  The engine event contract does not expose libmpv playlist-entry ids, so an
  old-source error first delivered after a new load has already begun cannot be
  distinguished at the service boundary. A failed queue load restores the
  command's pre-mutation queue and source snapshot before later commands run,
  while read-only and download/cache APIs remain outside the playback FIFO.
  Desktop native playback also owns Subsonic now-playing and scrobble
  submission in the main process. The playback FIFO only settles playing
  segments into the persistent `DesktopScrobbleBuffer`;
  `DesktopScrobbleSubmitter` uses the existing native bridge
  credential/request path asynchronously, applies the mobile threshold
  (`min(duration * 50%, 240s)`), and retries pending entries in order on ready
  or later playback opportunities. Each play has a stable entry id so a
  successful retry removes exactly that play even when the same song appears
  more than once. The renderer `useScrobble` hook remains active only for Web
  Audio, including Electron fallback, as gated by
  `shouldUseNativePlaybackBackend()`.
  Special desktop volume behavior: the
  Electron bridge keeps the mobile `setSystemVolume` method name for contract
  parity, but it controls only the embedded player/libmpv volume and must not
  change the user's OS output volume. See `docs/native-audio-libmpv.md` for
  build, smoke-test, packaging, diagnostics, and release details.
  The Node-API addon publishes active libmpv playback directly to each desktop
  system media surface: `MPNowPlayingInfoCenter` on macOS, SMTC on Windows,
  and MPRIS2 over the session D-Bus on Linux. Do not rely on the renderer Web
  Media Session for desktop native-audio registration; the renderer disables
  `navigator.mediaSession` via `shouldUseNativePlaybackBackend()`
  (`src/utils/setMediaSession.ts`) whenever the native backend owns the system
  media session, so the addon/plugin is the single source of truth. On macOS
  `electron/main/index.ts` also appends `disable-features=HardwareMediaKeyHandling`
  before `app.whenReady()`: Chromium's `HardwareMediaKeyHandling` feature (on by
  default for audio-playing Electron apps) otherwise claims the macOS Now Playing
  slot and routes Control Center / media-key commands to its own
  `RemoteCommandCenterDelegate`, starving the addon's `MPRemoteCommandCenter`
  handlers (play/pause, scrubber, and media keys stop firing). With it disabled
  the addon is the sole media session owner. On macOS the
  addon also registers `MPRemoteCommandCenter` handlers (required for Control
  Center / Now Playing visibility and media-key routing) and forwards system
  media commands back to JS as `system-media-command` events; these flow
  through `LibMpvAudioEngine` to `NativeAudioService.#handleSystemMediaCommand`,
  which applies seek/play/pause/toggle/next/previous directly to local playback
  (matching the desktop taskbar chrome's `handleRemoteCommand` path) so the
  system scrubber and media keys take effect without a main-process -> renderer
  -> main-process round-trip. `like`/`shuffle` still forward to the renderer as
  `remoteCommand` events (their state is owned there), and remote-control
  projection routes commands to the controlled device instead of acting
  locally. Remote projection metadata is also published through the Electron
  main-process engine even though coordination itself is native-owned. Native
  player instances own their last global system-session publication: teardown
  only clears a session still owned by that instance, and command-handler
  detachment precedes player/TSFN destruction so old or finalized players
  cannot clear or call into a newer owner. Windows routes SMTC transport
  buttons (play/pause/next/previous) back to JS the same way, but the classic
  `SystemMediaTransportControls`
  API has no seek/scrubber command, so Windows position changes are
  display-only; Linux routes MPRIS Player method calls (play/pause/playpause/
  stop/next/previous/seek/setposition) back to JS through the same dispatcher,
  advertises only the capabilities it can prove from the active track and
  command handler (queue-bound next/previous remain false), exposes a fixed
  playback rate of 1.0, validates `SetPosition` track ids and bounds, and emits
  `Seeked` only after the async seek is reflected back into the native media
  state. It answers `Get`/`GetAll` for both the Player and Root interfaces with
  a full introspection XML. MPRIS `Stop` dispatches the shared native stop
  command, which clears local playback; `OpenUri` is unsupported. The addon
  reads `artworkUrl` from
  `NativeAudioMetadata`: on macOS it asynchronously fetches the image and sets
  `MPMediaItemArtwork` (cached per-URL, stale downloads are ignored); on Linux
  it exposes `mpris:artUrl`. Linux accepts only a cached local `file://` URI and
  omits artwork on a cache miss so authenticated Subsonic URLs and replayable
  credentials are never published on the session bus. Platform artwork
  consumers cannot resolve the renderer's `aonsoku-media://` custom protocol,
  so `electron/main/core/events.ts` wires an `artworkUrlResolver`
  into the desktop audio service that translates `aonsoku-media://getCoverArt`
  URLs (renderer-driven loads) and bare cover-art ids (queue-driven loads) into
  a safe local cached file for Linux or authenticated Subsonic HTTP URLs on
  macOS/Windows before metadata reaches the engine. The
  service also re-syncs the system media session's elapsed time after a seek
  so the Now Playing scrubber stays accurate between play/pause updates.
  Windows sets the SMTC `Thumbnail` from the resolved HTTP `artworkUrl` via
  `RandomAccessStreamReference::CreateFromUri`, letting the OS fetch the
  image. Linux builds require
  the system `dbus-1` development package in addition to libmpv headers.
- `src/player/queue-controller/` — queue management
  (`web-controller` / `native-controller`). Runtimes with native playback
  support, including Electron when the desktop bridge is available, attempt the
  native controller first and fall back to the web controller on construction
  failure.
- `src/store/player/playback-actions.ts` — runtime-aware action dispatch.
- `src/utils/capabilities.ts` — runtime detection and capability matrix.

### CI Native Audio Builds

The Electron build/release/nightly GitHub Actions workflows compile the libmpv
Node-API addon on every target platform/arch through the reusable composite
action `.github/actions/setup-native-audio`. It installs or fetches libmpv
development files, runs `pnpm native-audio:build`, stages the runtime
libraries into `resources/native-audio/<platform>-<arch>/`, and runs
`pnpm native-audio:smoke:packaged` before the Electron build.

- **macOS**: `brew install mpv`; `scripts/native-audio/ci/collect-runtime-darwin.mjs`
  walks the `otool -L` closure of `libmpv.2.dylib`, copies the Homebrew dylib
dependency set into a staging directory, rewrites their install ids and
cross-references to `@loader_path/<name>`, and patches the addon's libmpv
reference. The x86_64 build runs on `macos-15-intel` (the last GitHub-hosted
Intel runner; `macos-13` is retired) and the arm64 build on `macos-latest`.
- **Windows**: `scripts/native-audio/ci/fetch-libmpv-windows.mjs` downloads the
`mpv-dev-<arch>` and `mpv-<arch>` archives from `shinchiro/mpv-winbuild-cmake`,
stages the runtime DLLs, and generates an MSVC-compatible `mpv.lib` import
library from `libmpv-2.dll` with `dumpbin`/`lib` (via `ilammy/msvc-dev-cmd`).
The `electron/node-gyp` fork is archived (2025-10-11) and pinned via a git
tarball, so it never gained Visual Studio 2026 (version 18) support; current
GitHub Actions Windows runners (`windows-latest`, `windows-11-arm`) resolve to
the `win25-vs2026` image. `build-addon.mjs` therefore invokes the idempotent
`scripts/native-audio/ci/patch-node-gyp-vs2026.mjs` on Windows before spawning
node-gyp, backporting the VS 2026 / `v145` toolset detection from upstream
nodejs/node-gyp 69e5fd2 into the installed `@electron/node-gyp`
`find-visualstudio.js` in place. Electron build/release/nightly workflows also
install Windows dependencies with `--ignore-scripts`, apply that patch, then
run `pnpm rebuild --pending` before native-audio setup; this allows dependency
install scripts (including sharp on Windows ARM64) to use VS 2026 too.
The packaged smoke fixture stays paused during system-session/probe setup,
seeks before resuming, and waits for playback progress before stopping. This
prevents a slow runner from exhausting the two-second WAV before seeking.
The Linux addon's `$ORIGIN` rpath is
single-quoted in `binding.gyp` (`-Wl,-rpath,'$$ORIGIN'`) so the shell does not
expand it to empty before the linker records it.
- **Linux**: builds an **audio-only libmpv from source** via
  `scripts/native-audio/ci/build-libmpv-linux.mjs` (meson + ninja, mpv source
  pinned to a release commit SHA in `RELEASE_MPV_VERSIONS` and verified with
  `git rev-parse HEAD` after clone/fetch) with all video output, GPU, display,
  and hardware-acceleration features disabled (`-Dgl/vulkan/egl/wayland/x11/drm/vaapi/vdpau/libplacebo
  =disabled` etc.). The distro `libmpv-dev` / `libmpv2` package is
  intentionally not used because it transitively depends on the graphics
  stack (GL/EGL/Vulkan/X11/DRM/libplacebo), making runtime bundling
  impractical. The audio-only `libmpv.so` only depends on FFmpeg, libass,
  audio output client libs (ALSA + PulseAudio), and base-system libs.
  `scripts/native-audio/ci/collect-runtime-linux.mjs` walks the `ldd`
  dependency closure, copies every non-base-system `.so` into a flat staging
  directory using soname filenames, and applies `patchelf --set-rpath
  '$ORIGIN'` so the bundled libs resolve each other without touching system
  paths. Build deps: `build-essential git meson ninja-build pkg-config
  patchelf libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev
  libswresample-dev libswscale-dev libass-dev libpulse-dev libasound2-dev
  libdbus-1-dev dbus-daemon squashfs-tools`. All three Linux makers (`.deb`, `.rpm`, AppImage) bundle
  the audio-only libmpv runtime closure and declare **no** libmpv-related
  package dependency. They do declare a **glibc baseline dependency**
  (`depends: ["libc6 (>= 2.35)"]` / `requires: ["glibc >= 2.35"]` in
  `forge.config.ts`) because CI builds on Ubuntu 22.04 (glibc 2.35). The
  resulting packages require glibc >= 2.35 at runtime.
  Linux CI uses strict `--require-runtime-libs` verification, same as macOS
  and Windows. Linux installs `dbus-daemon` and runs the packaged smoke check
  inside an isolated `dbus-run-session` because GitHub-hosted Linux runners
  are headless. The addon immediately skips optional MPRIS registration when
  `DBUS_SESSION_BUS_ADDRESS` is absent, so missing desktop integration cannot
  block playback. The `build:linux`, `make`, and `publish` npm scripts also run
  `scripts/native-audio/run-packaged-smoke.mjs --only linux`, which starts the
  same isolated session bus (it is a no-op on macOS/Windows). On a Linux host,
  `verify-libmpv-package.mjs` additionally invokes
  `scripts/native-audio/linux-runtime-linkage.mjs`, which runs `ldd` and
  `readelf -d` on the addon and every bundled `.so`: no dependency may be
  `not found`, every bundled `.so` must carry a `$ORIGIN` rpath/RUNPATH, and
  the addon's `libmpv.so` must resolve to a path inside the bundle directory
  (proving the `$ORIGIN` bundle is self-contained rather than binding to a
  system libmpv). macOS/Windows and cross-builds skip the deep check. The
  AppImage target (`@reforged/maker-appimage`) is built
  alongside the `.deb`/`.rpm` by `electron-forge make --platform linux` and
  is now self-contained; it shells out to the system `mksquashfs`
  (`squashfs-tools`) and downloads the AppImage type2 runtime at make time.

### Modification Rules

When modifying playback-related functionality, **all stacks must remain
feature-consistent**:

1. Playback logic changes -> update both `web-backend.ts` and
   `native-backend.ts` when the behavior applies to both.
2. Queue logic changes -> update both `web-controller.ts` and
   `native-controller.ts`.
3. Playback action changes -> ensure Web/Electron and Capacitor native branches
   are covered in `playback-actions.ts`.
4. New playback features -> define them in the `PlaybackBackend` interface and
   implement/degrade them in all backends.
5. Platform capability differences (`capabilities.ts`) -> degrade gracefully
   when unavailable, never silently ignore.
6. Remote-control or handoff changes -> verify local playback, remote playback
   projection, and native coordination paths.

### Native Player Debug Window (Electron desktop)

A developer/debug window mirroring the mobile `DebugViewController` /
`DebugActivity` (Playback / Info / Logs tabs, 2s auto-refresh). Entry point is
macOS-only, under the View application menu ("Native Player Debug…"); other
platforms have no menu entry yet. The window is a standalone `BrowserWindow`
that loads the dedicated Electron-only renderer entry
`electron/renderer/native-debug/index.html` (not part of the shared `src/` SPA).

- Main-process debug surface lives in `electron/main/native/debug/`:
  `NativeDebugLogger` (ring buffer, mirroring mobile `NativeLogger`),
  `debug-provider` (aggregates `NativeFullState` + libmpv diagnostics +
  credentials + process info + logs into one snapshot), and IPC handlers
  (`aonsoku-native-debug:snapshot|control|clear-logs`). The window itself is
  managed in `native-debug-window.ts`; `NativeAudioService.getDebugExtras()`
  exposes engine diagnostics + the live buffering flag.
- Preload bridge `electron/preload/native-debug.ts` exposes
  `window.aonsokuNativeDebug`; `window.api.openNativeDebug()` opens the window.
- The main native audio stack (`DesktopNativeAudioService`,
  `DesktopQueueEngine`, `LibMpvAudioEngine`) is instrumented with
  `nativeLogger` calls (sources `audio-service` / `queue-engine` /
  `libmpv-engine`) so the Logs tab shows real activity. Avoid logging
  progress events (too noisy).
