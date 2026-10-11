# Android native replacement audit

Scope: the current checkout's Android-visible application. No implementations
from other branches were inspected. The reference is `src/routes/router.tsx`,
`src/app/pages/mobile`, the shared detail/player components, the settings pages,
and their stores/services. Desktop-only Discord RPC, tray, desktop updates,
browser PiP permission, and pointer cursors are not Android workflows.

## Reference inventory and acceptance

| Area | Reference | Native acceptance |
| --- | --- | --- |
| Authentication | login.tsx, server settings, app.store.ts | encrypted credentials, primary/fallback URL, probing, logout, existing-session upgrade |
| Home | home.tsx, use-home.ts | carousel/discovery, pinned items, recent/most/new/random albums, refresh, device overview |
| Library | mobile/library.tsx | artists, albums, songs, favorites, playlists, radio; empty/loading/error states |
| Browsing | albums/list, artists/list, songs/songlist | paging, search, sorting, genre/year filters; no fixed collection truncation |
| Details | album.tsx, artist.tsx, playlist.tsx | cover, metadata, album songs, discography/top tracks, navigation |
| Library actions | song/, table/context-menu | play/shuffle, play next/last, favorites, rating, info, download, playlist, artist/album navigation, pin/share |
| Playlists | playlist/form-dialog, options, remove-song-dialog | create/edit/public/delete, append/remove/reorder songs, ownership, play/shuffle |
| Radio | radios-list, radios/form-dialog | list/create/edit/delete, direct stream playback |
| Player | player/, fullscreen/ | compact/fullscreen player, buffering/errors, seek, volume, favorite, shuffle/repeat, queue, lyrics, sleep timer |
| Queue | player/queue-actions, queue-controller | context/manual queue/history order, replace confirmation, play/remove/reorder/clear, restoration |
| Lyrics | fullscreen/lyrics, custom-lyrics-select | server/LRCLIB/custom source order, selection, synced/plain text, translation, offset, seek, disable/reset |
| Downloads | storage/cache-manager, cache adapters | progress/cancel/retry, explicit/smart/LRU/assets pools, quotas, item deletion, offline playback |
| Appearance | settings/appearance, theme.store | system/light/dark, named color themes, Material You, fullscreen-on-play, album cover preference |
| Audio/settings | settings/audio, player/initial-state | haptics, ReplayGain mode/preamp/default, lyric preferences/custom URL, history size |
| Content/language/privacy | settings/content, language, privacy | hide radio, locale, LRCLIB opt-in |
| Coordination | settings/cross-device, coordination/, native plugin | registration/tokens, fresh tickets/reconnect, presence/snapshots, control/projection, handoff/rollback/fencing, history sync, device management |
| Lifecycle | observers/, MainActivity, PlaybackService | back, state restoration, network/fallback, notifications/lockscreen/Bluetooth, foreground/background, debug shake |

## Incremental delivery

1. Native build/launcher, Compose Expressive theme, floating navigation, login,
   typed service binding, local library/home/search/details, compact/full player.
2. Server mutations and library workflows, playlist/radio editing, queue policy,
   lyrics, download/cache management, history and settings migration.
3. Move coordination lifetime out of the Capacitor adapter; implement native
   account/session orchestration, device/control/handoff UI and lifecycle flows.
4. Close the audit against actual behavior, build/unit tests, non-destructive
   connected-device acceptance, and Android packaging/CI.

This file is an acceptance ledger, not a claim of completion. Each delivery
records its actual verified range below; unresolved entries must remain visible.

## Verification log

- Initial audit: launcher is BridgeActivity; authentication, preferences,
  Room library, Media3 playback/queue/downloads already have typed boundaries.
  Coordination socket and registration/history orchestration still depend on
  the plugin and TypeScript. Connected Pixel 5 has a debuggable installed app.
- Stage 1: Compose app compiles; 133 existing native service unit tests pass;
  repository Biome lint passes (1037 files). Home/library/search/details and
  compact/full player use typed services. Playlist editing, radio, downloads,
  lyrics, full settings and coordination are still pending at this checkpoint.
- Device startup follow-up: a locked-device launch exposed an Android background
  service start restriction. Bind-only initialization now defers startService
  until a user playback command. Fixed NativeLogger's Java 21 List.removeFirst
  linkage on Android 14. APK rebuild and all 133 unit tests pass; Pixel 5 renders
  the native home and floating navigation after a data-preserving install.
- Stage 2 service layer: typed playlist create/edit/delete/add/remove/replace
  operations preserve repeated IDs and ownership; radio CRUD, favorites/rating,
  artist info/top tracks, native play history, queued download progress and
  explicit/smart/LRU cache sources are available without a WebView. Queue
  replacement confirmation lives before native dispatch. Compile and original
  native tests pass; added encoding/duplicate/decoder regression coverage.
- Native lyric service: server structured/plain lyrics, LRCLIB privacy opt-in,
  custom-server candidates/romanization, source ordering, prefer-synced fallback,
  explicit selection and offline cache. Regression tests cover multiple LRC
  timestamps, fractions, offset, plain text and same-time translations.

- Stage 3: Compose settings, themes/locales, fullscreen timed lyrics, editable
  queue, playlist/radio actions and download UI compile. The socket/protocol
  engine now lives in NativeCoordinationService; native CoordinationController
  owns registration/refresh/tickets/retry, device management, remote projection,
  handoff and persisted history outbox/cursor/tombstones. ReplayGain has a native
  PCM processor. Device home/library rendering and data-preserving upgrade pass.
  Background download maintenance, UI acceptance and packaging closure remain.
