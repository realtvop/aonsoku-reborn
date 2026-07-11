# AGENTS.md

This file provides guidance to coding agents when working with code in this
repository.

## Project Overview

Aonsoku is a multi-runtime music streaming client for Navidrome/Subsonic
servers. It targets the web, Electron desktop, and Capacitor iOS/Android. It
supports synchronized lyrics, radio streaming, Discord RPC, offline
library/cache features, and cross-device coordination with remote control and
handoff.

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
pnpm run electron:build   # Electron renderer/main/preload build
pnpm run make             # Create Electron distributable packages

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

# Android native plugin
cd android && ./gradlew :aonsoku-capacitor-native:compileDebugKotlin
cd android && ./gradlew :aonsoku-capacitor-native:testDebugUnitTest

# Electron desktop native audio
pnpm native-audio:build   # Build the Node-API libmpv addon
pnpm native-audio:prepare # Copy addon/runtime libs into resources/native-audio
pnpm native-audio:smoke   # Load libmpv and play a generated WAV fixture
pnpm native-audio:smoke:packaged # Smoke test resources/native-audio layout
pnpm native-audio:verify-package # Check Forge/resource/native-audio packaging
pnpm native-audio:verify-package:strict # Fail if native runtime files are missing

# CI helpers used by .github/actions/setup-native-audio
node scripts/native-audio/ci/fetch-libmpv-windows.mjs --arch x64|arm64
node scripts/native-audio/ci/collect-runtime-darwin.mjs --root <libmpv.dylib> --staging <dir> --addon <addon.node>
```

## Architecture

### Multi-Target Build

- **Web**: Vite (`vite.config.ts`) builds `src/` as a standard SPA.
- **Electron**: `electron.vite.config.ts` builds `electron/main`,
  `electron/preload`, and the renderer, which reuses `src/`.
- **Capacitor iOS/Android**: `capacitor.config.ts` points native hosts at
  `dist`. The custom native plugin lives in
  `capacitor-plugins/capacitor-native` and is included through pnpm workspace
  package `@aonsoku/capacitor-native`.
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
`playback-state.json`). The web/Electron-fallback path still rehydrates the
songlist from IDB and drives `load()` + `pendingResumePosition` from the renderer.

### Sync Architecture

Metadata/library sync is runtime-specific:

- **Web**: `src/service/cache/sync-worker-adapter.ts` creates
  `src/service/cache/sync.worker.ts` and communicates with it via Comlink.
  The worker owns its own Dexie instance, receives auth via
  `initAuth`/`updateAuth`, and bridges sync state/query invalidation back to
  the main thread.
- **Worker fallback**: if Web Workers are unavailable, sync falls back to
  `src/service/cache/metadata-sync.ts` on the main thread.
- **Electron, Capacitor iOS/Android**: sync uses
  `src/native/data/native-sync-adapter.ts` and the runtime's
  `AonsokuNativeData` implementation. Electron implements the bridge in
  `electron/main/native/data/`; mobile uses the Capacitor plugin. Native
  runtimes do not fall back to the browser Worker/IndexedDB sync path.

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
  lyrics metadata, and cover/avatar downloads.
- `electron/main/native/preferences/` owns Electron desktop preference
  persistence exposed through `AonsokuNativePreferences`; renderer-side
  Zustand/UI preference stores should use `src/store/native-storage.ts` instead
  of adding new Electron renderer `localStorage` persistence.
- `electron/main/native/coordination/` owns coordination HTTP, token/config
  persistence, and the realtime WebSocket.
- `electron/main/native/media-protocol.ts` resolves renderer-facing
  `aonsoku-media://` cover/avatar/stream identifiers and injects credentials in
  the main process. Renderer code must not construct authenticated server URLs.

### Cross-Device Coordination

Aonsoku includes a Rust coordination service in `coordination-server/` for
device registration, presence, playback snapshots, remote control, history
sync, and handoff. The client-side orchestration lives in `src/coordination/`
with React state in `src/coordination/store.ts`.

- Web uses the TypeScript WebSocket client (`src/coordination/wsClient.ts`).
- Electron, iOS, and Android use `src/native/coordination/facade.ts` and their
  runtime-native coordination implementations.
- The root app mounts `CoordinationObserver`, and player/fullscreen/lyrics
  surfaces can project remote playback through
  `src/app/components/remote-control/`.

When changing playback controls, queue semantics, lyrics timing, scrobbling, or
handoff behavior, check local playback, remote-control projection, and native
coordination behavior together.

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

Manual chunk strategy is defined in root `manual-chunks.ts` and imported by
both Vite and Electron Vite configs. Update it when adding large dependencies
or moving substantial lazy-loaded feature areas.

## Tooling Notes

- **Package manager**: pnpm only.
- **Workspace**: root app plus `capacitor-plugins/*`.
- **Linter/formatter**: Biome 2.0.6 — double quotes, trailing commas,
  80-character line width, no unused vars/imports.
- **TypeScript**: strict mode, path alias `@/` -> `src/`.
- **Rust**: coordination server is a separate Cargo project under
  `coordination-server/`.
- **Native**: Android host lives under `android/`; iOS host lives under `ios/`;
  shared Capacitor plugin source lives under
  `capacitor-plugins/capacitor-native/`.
- **Git hooks**: Husky is configured (`.husky/`) and pre-commit runs
  `pnpm lint`.

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
| Native audio (Capacitor plugin) | capacitor-ios, capacitor-android | `src/player/playback/native-backend.ts` |
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
  APIs remain usable. `make`, `publish`, and platform package scripts run strict native
  audio verification and fail if addon/runtime files are missing; development
  `build:unpack` runs the non-strict verifier. The Electron service includes a
  desktop queue engine aligned with the mobile native plugin contract for
  context/user queues, shuffle/repeat, full-state export, scrobble buffering,
  sleep timers, remote playback projection, and a platform-scoped system
  adapter for HUD/like integration. Special desktop volume behavior: the
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
  locally. Windows routes SMTC transport buttons (play/pause/next/previous)
  back to JS the same way, but the classic `SystemMediaTransportControls`
  API has no seek/scrubber command, so Windows position changes are
  display-only; Linux routes MPRIS Player method calls (play/pause/playpause/
  stop/next/previous/seek/setposition) back to JS through the same dispatcher,
  advertises `CanPlay`/`CanPause`/`CanSeek`/`CanGoNext`/`CanGoPrevious`/
  `CanControl` as true, emits the `Seeked` signal after position changes, and
  answers `Get`/`GetAll` for both the Player and Root interfaces with a full
  introspection XML. MPRIS `Stop` maps to the contract's `pause` command (there
  is no stop command), and `OpenUri` is unsupported. The addon reads `artworkUrl` from
  `NativeAudioMetadata`: on macOS it asynchronously fetches the image and sets
  `MPMediaItemArtwork` (cached per-URL, stale downloads are ignored); on Linux
  it exposes `mpris:artUrl`. The platform HTTP clients (NSURLSession, D-Bus
  MPRIS clients) cannot resolve the renderer's `aonsoku-media://` custom
  protocol, so `electron/main/core/events.ts` wires an `artworkUrlResolver`
  into the desktop audio service that translates `aonsoku-media://getCoverArt`
  URLs (renderer-driven loads) and bare cover-art ids (queue-driven loads) into
  authenticated Subsonic HTTP URLs before metadata reaches the engine. The
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
- **Linux**: builds an **audio-only libmpv from source** via
  `scripts/native-audio/ci/build-libmpv-linux.mjs` (meson + ninja, pinned mpv
  release) with all video output, GPU, display, and hardware-acceleration
  features disabled (`-Dgl/vulkan/egl/wayland/x11/drm/vaapi/vdpau/libplacebo
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
  libdbus-1-dev squashfs-tools`. All three Linux makers (`.deb`, `.rpm`, AppImage) bundle
  the audio-only libmpv runtime closure and declare **no** libmpv-related
  package dependency (`depends: []` / `requires: []` in `forge.config.ts`).
  Linux CI uses strict `--require-runtime-libs` verification, same as macOS
  and Windows. The AppImage target (`@reforged/maker-appimage`) is built
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
