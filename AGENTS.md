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

### Sync Architecture

Metadata/library sync is runtime-specific:

- **Web/Electron**: `src/service/cache/sync-worker-adapter.ts` creates
  `src/service/cache/sync.worker.ts` and communicates with it via Comlink.
  The worker owns its own Dexie instance, receives auth via
  `initAuth`/`updateAuth`, and bridges sync state/query invalidation back to
  the main thread.
- **Worker fallback**: if Web Workers are unavailable, sync falls back to
  `src/service/cache/metadata-sync.ts` on the main thread.
- **Capacitor iOS/Android**: sync uses `src/native/data/native-sync-adapter.ts`
  and the native `AonsokuNativeData` plugin. Native platforms do not fall back
  to the browser Worker/IndexedDB sync path.

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

### Cross-Device Coordination

Aonsoku includes a Rust coordination service in `coordination-server/` for
device registration, presence, playback snapshots, remote control, history
sync, and handoff. The client-side orchestration lives in `src/coordination/`
with React state in `src/coordination/store.ts`.

- Web/Electron use the TypeScript WebSocket client
  (`src/coordination/wsClient.ts`).
- iOS/Android use `src/native/coordination/facade.ts` and the native
  coordination plugin.
- The root app mounts `CoordinationObserver`, and player/fullscreen/lyrics
  surfaces can project remote playback through
  `src/app/components/remote-control/`.

When changing playback controls, queue semantics, lyrics timing, scrobbling, or
handoff behavior, check local playback, remote-control projection, and native
coordination behavior together.

### Routing

React Router v6 uses hash routing. Route constants live in
`src/routes/routesList.ts`. Auth is enforced via loaders
(`protectedLoader.ts`, `loginLoader.ts`) — always use named route constants from
`ROUTES` rather than hardcoded strings.

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

Key files:

- `src/player/playback/types.ts` — unified `PlaybackBackend` interface.
- `src/player/playback/backend-factory.ts` — platform-aware backend selection.
- `src/native/audio/` — native audio facade and shared TS types.
- `src/player/queue-controller/` — queue management
  (`web-controller` / `native-controller`).
- `src/store/player/playback-actions.ts` — runtime-aware action dispatch.
- `src/utils/capabilities.ts` — runtime detection and capability matrix.

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
