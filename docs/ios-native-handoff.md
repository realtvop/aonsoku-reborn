# Native iOS app: handoff

This file hands the rest of the native iOS app to the next agent: what is
done, the rules, and the remaining work, with a full spec for each package.
Delete it in the final commit, once everything durable in it lives in
`docs/ios-native-app.md` and `AGENTS.md`.

## Goal

Replace the Capacitor iOS app with a fully native SwiftUI app for iOS 26
that uses Liquid Glass. Apple Music is the reference for navigation,
interactions, motion and polish. The app needs complete feature and behavior
parity with the web app, including every setting and workflow. The
architecture is in `docs/ios-native-app.md`.

## State at handoff (2026-10-21)

Branch `feat/ios-native-app/drafts/claude-opus-5.5`.

Done:

- A native app shell (`ios/Aonsoku.xcodeproj`, same bundle identifier)
  replaces the Capacitor host. The former plugin's Swift services live in the
  `AonsokuKit` package: `AudioService`, `LibraryService`,
  `AuthenticationService`, `PreferencesService`, `AppLifecycleService`.
- `CoordinationService` (HTTP, WebSocket transport, snapshots, remote
  commands, handoff) is finished and reviewed.
- The whole SwiftUI interface under `ios/Aonsoku/` is finished:
  - design system, tabs and login;
  - Home, Library and Search;
  - album, artist, playlist, genre and song screens;
  - the mini player, and Now Playing with lyrics and queue;
  - the devices sheet, and the account sheet with every settings page.
- Store contracts in `ios/AonsokuKit/Sources/AonsokuKit/Stores/`: every
  public type, property and method exists, and its doc comment is its
  specification. `AppModel` creates and connects the stores.
- `LiveSubsonicAPI` covers every endpoint the app uses and is tested.
- Native-only strings (`ios/native-locales/`) exist in all 18 languages.
- 217 AonsokuKit tests pass and the app builds.

Not done: the store logic. Most store methods are still empty, so the app
cannot sign in, browse or play yet. The seven packages below implement it.

## Rules

Follow `AGENTS.md`: the commit format, pnpm only, and the Husky pre-commit
hook that runs `pnpm lint` (never bypass it). In addition:

- **Branch and commits:** work on this branch and commit each validated
  step separately. Don't push, open a pull request or merge unless the user
  asks.
- **Other branches:** don't read or check out other branches or worktrees.
  Other drafts of this app exist, and this work must stay independent of
  them. Everything you need is on this branch, and its web, Electron and
  Android code is the behavior reference. Leave the
  `interesting-chatelet-1d98b8` and `slider-spec` worktrees alone.
- **Credentials:** don't read environment variables, the Keychain or
  credentials, and don't type credentials anywhere. Tests never touch the
  real network.
- **Disk:** the disk is nearly full (about 3 GB free).
  - Build with the default DerivedData folders, which already hold the
    resolved packages.
  - Delete only build products you created.
  - Never `git add` the untracked `ios/App/` and
    `ios/capacitor-cordova-ios-plugins/` folders. They are cap-sync
    leftovers that belong to the user.
- **Simulator:** use "Aonsoku Dev" (`FFD4B086-2808-4670-B1C6-BAD68AF89976`).
  Never erase or delete a simulator.
- **Physical device:** ask the user before installing on one. During device
  tests the media volume stays at 0: no volume keys and no unmuting.
- **UI design:** the UI is designed and finished. Keep its design, and
  change views only where wiring needs it.
- **Store API:** the public store API is the UI's contract. Keep it stable.
  When a change is unavoidable, update the SwiftUI call sites in the same
  commit.
- **Swift style:** Swift 5 language mode, iOS 26, 4-space indentation, and
  no warnings in new code. Stores are `@MainActor @Observable`. No TODO
  comments, stubs, `fatalError`, or force unwrapping of stored or server
  data.
- **Callback queues:** `AudioService` and `LibraryService` call back on their
  own queues. Hop to the main actor with `Task { @MainActor in ... }`. Never
  observe `.aonsokuAudioStateDidChange` (or any audio notification) with
  `queue: .main`: that deadlocks against `AudioService.stateQueue.sync`.
- **App target isolation:** the app target defaults to main-actor isolation.
  Pass closures (`{ f($0) }`) rather than unapplied method references to
  nonisolated APIs. `.tint.gradient` does not exist; use
  `Color.accentColor.gradient`.
- **Server calls:** every server call goes through `SubsonicAPI`, which
  throws only `SubsonicAPIError`. Use `isConnectivityFailure` to decide when
  a cached copy may stand in.

## Build and test

```bash
# AonsokuKit tests (217 pass at handoff)
IOS_SIMULATOR_ID=FFD4B086-2808-4670-B1C6-BAD68AF89976 ./scripts/test-ios-native.sh

# One suite while iterating
cd ios/AonsokuKit && xcodebuild -quiet test -scheme AonsokuKit \
  -destination "platform=iOS Simulator,id=FFD4B086-2808-4670-B1C6-BAD68AF89976" \
  CODE_SIGNING_ALLOWED=NO -only-testing:AonsokuKitTests/<SuiteName>

# App build
xcodebuild -project ios/Aonsoku.xcodeproj -scheme Aonsoku \
  -destination 'generic/platform=iOS Simulator' build

# Translation keys used by the Swift sources, then lint
node scripts/check-ios-strings.mjs
pnpm run lint
```

For each package:

1. Read its spec and the files it names.
2. Implement it, adding focused tests through internal seams.
3. Run its suites, then the whole Kit suite and the app build.
4. Commit, for example `feat(ios): implement the library read layer`.

## Remaining work, in order

1. WP-B1b, library reads: `LibraryRepository`, `HomeStore`,
   `NetworkMonitor`, `ArtworkProvider`.
2. WP-B2a, session and settings: `SessionStore`, `SettingsStore`,
   `SettingsMigration`, `Localizer`.
3. WP-B2b, collections: pinned items, favorites, playlists, radio, listening
   history, and the `LibraryService` local edits.
4. WP-C, playback: `PlayerStore` and ReplayGain.
5. WP-D, lyrics: `LyricsStore`.
6. WP-E, downloads and import: `DownloadsStore` and `LegacyWebDataImporter`.
7. WP-F, cross-device and sync: `CoordinationStore`, `LibrarySyncStore`, and
   the cover art sync phase.
8. Integration: run every flow in the simulator and fix the gaps.
9. CI, docs and `AGENTS.md`.
10. Final validation, then delete this file.

## Packages

Paths such as `Stores/X.swift` are relative to
`ios/AonsokuKit/Sources/AonsokuKit/`. The doc comments on each store's public
members are its specification, and the web code each spec names is the
behavior to mirror. "Files" lists where the work is expected to go; touch
other files only when the work needs it.

### WP-B1b: Library reads

Implement the library read layer: `LibraryRepository`, `HomeStore`, `NetworkMonitor` and `ArtworkProvider`.

**Files:** `ios/AonsokuKit/Sources/AonsokuKit/Stores/LibraryRepository.swift`, `Stores/HomeStore.swift`, `Stores/NetworkMonitor.swift`, `Stores/ArtworkProvider.swift`. You may add new source files under `ios/AonsokuKit/Sources/AonsokuKit/Stores/` (for example `LibraryMapping.swift` for record-to-model conversion) and new test files under `ios/AonsokuKit/Tests/AonsokuKitTests/`.

#### Read first

- The four files above: every public method has a doc comment that is the specification.
- `ios/AonsokuKit/Sources/AonsokuKit/API/SubsonicAPI.swift` (the server API you call through `api`, fully implemented and tested) and `Model/MediaModels.swift` (the value types you return: Song, Album, AlbumDetail, Artist, ArtistDetail, Playlist, PlaylistDetail, Genre, SearchResults, AlbumListFilter, SongListQuery, SongSort, LibraryPage...).
- `ios/AonsokuKit/Sources/AonsokuKit/Data/LibraryService.swift` and `Data/LibraryModels.swift`: the synced local library (GRDB). Also read `Data/Repositories/AlbumRepository.swift`, `ArtistRepository.swift`, `SongRepository.swift`, `PlaylistRepository.swift` and `Data/Database/SearchHelper.swift` to learn which `sortBy` values and filters the local queries support, and `Data/Models/*Record.swift` for the stored fields (some are JSON strings such as `genresJson`, `replayGainJson`, `entriesJson`).
- `ios/AonsokuKit/Sources/AonsokuKit/Image/` for the cover cache used by `LibraryService.resolveCover`, `downloadCover`, `downloadAvatar` and `coverSize`.
- The web behavior you mirror: `src/queries/songs.ts`, `src/queries/albums.ts`, `src/lib/offlineQueryClient.ts`, `src/app/hooks/use-home.tsx`, `src/utils/albumsFilter.ts`, `src/service/search.ts`.
- Existing tests show how to build a temporary database and a `LibraryService` over it: `ios/AonsokuKit/Tests/AonsokuKitTests/LibraryServiceTests.swift`, `SearchAndSyncTests.swift`, `TestSupport.swift`.

#### What to implement

##### LibraryRepository
- "Local ready" means `library.availability().available` (a full sync has finished).
- `serverType` is the closure given to the initializer; it returns the signed-in server type (`navidrome`, `lms`, `subsonic`...) or nil.
- Lists (`albums`, `artists`, `songs(_:offset:limit:)`, `genres`, `playlists`): read the local library when it is ready; otherwise call the server. Pages are `LibraryPage(items:total:hasMore:)`; for server pages without a known total use `total = offset + items.count` and `hasMore = items.count == limit`.
- Album filters, local and server:
  - `alphabeticalByName` name ascending (`getAlbumList2` type `alphabeticalByName`); `alphabeticalByArtist` artist ascending; `recentlyAdded` created descending (`newest`); `recentlyPlayed` last played descending (`recent`); `mostPlayed` play count descending (`frequent`); `random` (`random`; locally shuffled); `favorites` starred only, most recently starred first (`starred`).
  - `byYear(newestFirst:)` release year descending or ascending (`byYear` with `fromYear`/`toYear` set to the current year and 0, swapped for oldest first, as the web does).
  - `byGenre(name)` albums with that genre, by name (`byGenre`).
  - `discography(artistId:)` the artist's albums, newest first (server: `api.artist(id:)`).
  - `search(text)` every word must match the name or artist (server: `search3` albums page).
- Artists: by name; `search` keeps artists whose name contains every word (case- and diacritic-insensitive); `starredOnly` lists favorites. Server fallback: `api.artists()` or `api.starred().artists`, filtered and paged in memory.
- Songs by `SongListQuery`: scope `all`, `favorites` (starred), `artist(id:name:)` (songs whose artist or album artist is that artist), `album(id:)` (in disc and track order), `genre(name)`; `search` words must all match title, artist or album; sort by `SongSort` (`recentlyAdded` = created, `title`, `artist`, `album`) and `ascending`. Server fallback: `all` via `search3` songs page with the query (for an empty search pass two double-quote characters `""` when `serverType()` is `navidrome`, else an empty string, as the web `search.ts` does); `favorites` via `api.starred().songs`; `artist` like the web `getArtistAllSongs` (every album of the artist, then their songs); `album` via `api.album(id:)`; `genre` via `api.songsByGenre`. Sort server results in memory the way the web `sortSongs` does.
- Details (`album`, `artist`, `playlist`, `song`): when online, ask the server; when offline, or when the server call fails with an error whose `isConnectivityFailure` is true, return the local copy; if there is no local copy, rethrow the original error. `cached*` variants return the local copy only (nil when missing), without touching the network. Artist details list albums newest first.
- `songs(ids:)`: local first, then the server (`api.song(id:)`) for misses when online; keep the input order; skip unknown ids.
- `albumInfo`, `artistInfo`, `topSongs`: server only; nil or empty when offline or on any error.
- `homeAlbums(_:size:)` and `carouselAlbums(size:)`: server lists when online (`recentlyPlayed` = `recent`, `mostPlayed` = `frequent`, `recentlyAdded` = `newest`, `explore` and the carousel = `random`); otherwise the local library as the doc comment says. If the server call fails with a connectivity failure, fall back to local.
- `search(_:limit:)`: `search3` when online; otherwise local, where every word must match. Empty or whitespace text returns empty results.
- `randomSongs(size:genre:)`: server when online; otherwise random local songs (optionally of that genre).
- `scanStatus()` and `startScan()`: pass through to the API.
- Map local records to models in one place. Parse JSON string columns defensively. Dates stored as ISO strings or milliseconds must become `Date`.

##### HomeStore
- `loadIfNeeded()` loads once (concurrent calls share one load); `refresh()` reloads the carousel and every `HomeSection` concurrently (`HomeSection.size` albums each, `HomeSection.carouselSize` for the carousel); a section that fails keeps its previous albums. `phase` goes `.loading` then `.loaded`, or `.failed(message)` only when everything failed and nothing was loaded before. `refreshRecentlyPlayed()` reloads only that section.

##### NetworkMonitor
- Use `NWPathMonitor` on a private queue. Update the observable properties on the main actor. `isOnline` is `path.status == .satisfied`; `isExpensive` and `isConstrained` from the path. `connectivity` must return the same values from any thread: replace the `FixedConnectivity()` with a lock-protected `Connectivity` implementation (for example a final class with an `OSAllocatedUnfairLock` or `NSLock`) that the monitor updates. `start()` is idempotent; `stop()` cancels the monitor, and `start()` after `stop()` works again.

##### ArtworkProvider
- `cachedImage(for:size:)`: memory cache only (an `NSCache` keyed by id and size); a larger cached size satisfies a smaller request.
- `image(for:size:)`: memory, then the cover file cache (`library.resolveCover`, but only when `library.coverSize(id:)` says the stored size is at least the requested size, or the stored size is unknown), then `library.downloadCover(id:size:)`. Decode and downscale off the main thread (`UIImage.preparingThumbnail(of:)` or ImageIO) to the requested pixel size; deduplicate concurrent requests for the same id and size; return nil on failure without throwing.
- `avatar(username:size:)`: the same through `library.downloadAvatar`, cached in memory per username and size.
- `palette(for:)`: from the medium image, compute four dominant colors (for example k-means or median cut on a 32x32 downsample, most prominent first, avoiding near-identical colors) and `isDark` from their weighted luminance; cache per id. Return nil when the image is unavailable.
- `purgeMemory()` empties the memory caches.

##### Tests
Add focused tests, for example `LibraryRepositoryTests.swift`, `HomeStoreTests.swift`, `ArtworkProviderTests.swift`:
- A fake `SubsonicAPI` that records calls and returns canned models, and a fake `Connectivity`.
- A temporary database with seeded records, through `LibraryService`'s internal initializer.
- Local versus server selection, every album filter and song scope and sort, paging values, offline and connectivity-failure fallbacks for details, `songs(ids:)` order, search word matching, home sections keeping old albums on failure, memory-cache size rules, and palette extraction on a generated image.

### WP-B2a: Session, settings and translations

Implement the session, settings, legacy-settings migration and translation stores: `SessionStore`, `SettingsStore`, `SettingsMigration` and `Localizer`.

**Files:** `ios/AonsokuKit/Sources/AonsokuKit/Stores/SessionStore.swift`, `Stores/SettingsStore.swift`, `Stores/Localizer.swift`, `Migration/SettingsMigration.swift`. You may add new source files next to them and new test files under `ios/AonsokuKit/Tests/AonsokuKitTests/`.

#### Read first

- The four files above; every public member has a doc comment that is the specification.
- `ios/AonsokuKit/Sources/AonsokuKit/Auth/AuthenticationService.swift`, `KeychainManager.swift`, `SubsonicHTTPClient.swift`: login with primary/fallback probing (`login(...)` returns `LoginResult`), credential storage, server info.
- `ios/AonsokuKit/Sources/AonsokuKit/API/SubsonicAPI.swift`: `ping()` returns `ServerInfo`; `user(username:)`.
- `ios/AonsokuKit/Sources/AonsokuKit/Preferences/PreferencesService.swift`: the key-value store (`getString`, `setString`, `getJSON`, `setJSON`, `remove`, `getPlayHistory`, `addToPlayHistory`...).
- `ios/AonsokuKit/Sources/AonsokuKit/Model/SettingsModels.swift`: `AppSettings` and its parts, tolerant decoding, `AppLanguage`.
- `ios/AonsokuKit/Sources/AonsokuKit/Stores/LibraryCollectionsStores.swift`: `PinnedItem` (stored under `pinned.v1`) for the migration.
- Web references: the login and server-URL logic in `src/app/pages/login.tsx`, `src/store/app.store.ts` (look for `saveServerUrls` and the fallback handling) and `src/api/httpClient.ts`; the legacy persisted stores in `src/store/theme.store.ts`, `lang.store.ts`, `app.store.ts`, `cache.store.ts` (`cache_settings`), `src/store/player/store.ts` and `src/store/player/persistence.ts` (`player_store`), `src/store/pinned-home.store.ts`, `src/store/playHistory.store.ts`, `src/store/native-migration.ts` (how those stores were written into the native preferences as `{"state": ..., "version": n}` JSON), and the lyrics selection storage (search `src` for where custom lyrics selections are persisted). For translations: `src/i18n/index.ts` (i18next options) and `src/i18n/locales/*.json`; the native overlay files are `ios/native-locales/*.json`.

#### What to implement

##### SessionStore
- `restore()`: read `ServerAccount` JSON from preferences key `session.account.v1`. If it exists, the state becomes `.signedIn(account)` even when the Keychain read fails at this moment (the Keychain can be locked before the first unlock after a reboot; requests read the credentials again later). If there is no account record but the Keychain has credentials (data from the earlier Capacitor app), rebuild the account from them (`primaryUrl` = stored server URL, `fallbackUrl`, `activeUrl` = stored server URL, `username`, `serverType`, `protocolVersion`, `authType`), save it, and sign in. Otherwise `.signedOut`. Never touch the network.
- `signIn(serverUrl:fallbackUrl:username:password:)`: normalize URLs (trim, drop trailing slashes), call the authentication login (it probes primary then fallback), store the credentials, save the account with the URL that answered as `activeUrl`, and set `.signedIn`. Map failures: wrong credentials to `SubsonicAPIError.authenticationFailed(message:)`; no server answering to a connectivity error (`.offline` or `.timedOut`); keep `.signedOut` on failure.
- `refreshUser()`: `api.user(username:)` when signed in; keep the previous value on failure.
- `updateServerUrls(primaryUrl:fallbackUrl:)`: like the web `saveServerUrls`: with the stored username, password and auth type, try the primary, then the fallback; the one that answers becomes active; store updated credentials and the account. If neither answers, throw and keep everything unchanged.
- `serverInfo()`: `try? await api.ping()`.
- `signOut()`: clear the credentials and remove `session.account.v1`; state `.signedOut`; `user` nil.

##### SettingsStore
- `load()`: decode `AppSettings` from `settings.v1` (tolerant: a missing or corrupt value gives defaults, unknown fields are ignored). `persist()`: encode and save to `settings.v1` after every change. Loading must not call `onChange` handlers.

##### SettingsMigration
- `run()`: when `settings.migrated.v1` is not set and no `settings.v1` exists yet, read the legacy zustand JSON stores from the preferences (`theme_store`, `lang_store`, `app_store`, `player_store`, `cache_settings`; each `{"state": ..., "version": n}`) and build `AppSettings`: theme mode and light/dark themes, language code (mapped to `AppLanguage.all` codes), album-cover-for-songs, hide radios section, ReplayGain (enabled, mode, pre-amp, default gain), lyrics preferences (synced, translation, source priority, custom server URL and password), LRCLIB privacy toggle, history size, cache quotas, smart download rules, cover art sync and concurrency, haptics, and `player_store.settings.colors.currentSongColorIntensity` into `appearance.nowPlayingColorIntensity`. Read the web stores to find each field's path. Values outside the model's ranges are clamped; unknown values keep defaults. Save `settings.v1`.
- `pinned_home_store` items become `[PinnedItem]` under `pinned.v1` (newest first, no duplicates) when `pinned.v1` does not exist.
- `player_history` songs (if stored in the preferences as JSON) are added to the native play history (`addToPlayHistory`) oldest first so the newest ends up first, unless the native history already has entries.
- Lyrics selections move to `lyrics.selections.v1` as the same JSON object keyed by song key, when that key does not exist.
- Set `settings.migrated.v1` to `"true"` at the end. Leave the legacy keys in place. A second run returns immediately.

##### Localizer
- Load `<bundle>/locales/<resourceName>.json` (i18next nested JSON) for the active language and English (`en`), plus the overlays `<bundle>/native-locales/<resourceName>.json` and `native-locales/en.json` when present. Lookup order: native overlay of the language, the language, native English, English, then the key itself. Look the folders up with `bundle.url(forResource:withExtension:subdirectory:)`.
- `setLanguage(code:)`: a code from `AppLanguage.all` selects it; nil follows `preferredLanguages` (match exact codes first, then by language and script/region: `zh-Hans-CN` to `zh-Hans`, `pt-PT` to `pt`, `pt-BR` to `pt-BR`, `es-MX` to `es-ES`, `fr-CA` to `fr-CA`, `en-GB` to `en-US`), falling back to `en-US`. Unknown codes behave like nil. Update `language` and `selectedCode`; cache parsed files.
- `t(_:_:)`: dotted key lookup; a non-string result is a miss. Replace `{{name}}` placeholders (spaces inside the braces allowed) from `args`; leave unknown placeholders as they are; no HTML escaping.
- `t(_:count:_:)`: i18next v4 plural keys: when `count == 0` and `<key>_zero` exists use it; otherwise the CLDR cardinal category for the language (`one`, `few`, `many`, `other`) with `<key>_<category>`, falling back to `<key>_other`, then `<key>`. Implement integer rules for: en, de, sv, it, es, pt (Portugal), ml, tr (one: n = 1); fr, fr-CA, pt-BR (one: n = 0 or 1); cs (one 1, few 2–4, other); pl (one 1; few n%10 in 2–4 and n%100 not in 12–14; many otherwise); ru, uk (one n%10 = 1 and n%100 ≠ 11; few n%10 in 2–4 and n%100 not in 12–14; many otherwise); ja, ko, zh-Hans (other only). `{{count}}` is replaced by the number, plus `args`.
- `has(_:)`: true when the key resolves in the active language or English (including overlays).

##### Tests
Add focused tests, for example `SessionStoreTests.swift`, `SettingsStoreTests.swift`, `SettingsMigrationTests.swift`, `LocalizerTests.swift`:
- Session restore paths (account record, Keychain-only rebuild, locked Keychain with a record, nothing), sign-in success and failure mapping, URL update keeping state on failure, sign-out clearing, all through your seams and an in-memory or temporary `PreferencesService` (see `PreferencesTests.swift` for how tests create one).
- Settings load defaults, corrupt JSON, round trip, `onChange` calls.
- Migration from realistic legacy JSON for every store, idempotence, existing native values left alone.
- Localizer with a temporary bundle directory holding small `locales/*.json` and `native-locales/*.json` files: overlay order, English fallback, key fallback, interpolation, every plural rule family, `_zero`, system language matching.

### WP-B2b: Library collections

Implement the library collection stores: `PinnedHomeStore`, `FavoritesStore`, `PlaylistsStore`, `RadioStore` and `ListeningHistoryStore`, plus four local-library edit methods of `LibraryService`.

**Files:** `ios/AonsokuKit/Sources/AonsokuKit/Stores/LibraryCollectionsStores.swift`; in `ios/AonsokuKit/Sources/AonsokuKit/Data/LibraryService.swift` only the bodies of the four methods under `// MARK: - Local edits` (`starredIds`, `setStarred`, `refreshPlaylist`, `removePlaylist`) plus new private helpers; internal methods you need in `Data/Repositories/*.swift` and `Data/Sync/SyncEngine.swift` (for example a method that fetches and stores one playlist, reusing the engine's existing playlist parsing). You may add new source files under `Stores/` and new test files under `ios/AonsokuKit/Tests/AonsokuKitTests/`.

**Note:** Every server call goes through `api` (`SubsonicAPI`), which throws only `SubsonicAPIError`; check `isConnectivityFailure` where the doc comments talk about connectivity.

#### Read first

- `LibraryCollectionsStores.swift`: every public member has a doc comment that is the specification.
- `API/SubsonicAPI.swift` and `API/SubsonicJSON.swift` (the Subsonic JSON helpers, including `SubsonicJSON.song(_:)`, which turns a Subsonic song object into `Song`), `Model/MediaModels.swift`, `Stores/LibraryRepository.swift` (details and lists, with local fallbacks), `Stores/ToastCenter.swift`, `Preferences/PreferencesService.swift` (`getJSON`/`setJSON`, `getPlayHistory`, `addToPlayHistory`, `clearPlayHistory`), `Data/LibraryService.swift`, `Data/LibraryModels.swift`, `Data/Repositories/*.swift`, `Data/Sync/SyncEngine.swift`.
- The web behavior you mirror: `src/store/pinned-home.store.ts` and `src/app/hooks/use-home.tsx` (`getPinnedHomeItems`, `sortPinnedHomeItemsByPlayedAt`); favorites in `src/service/star.ts` and its callers (search `star(` in `src/app` and `src/store`); playlists in `src/service/playlists.ts` and the playlist dialogs under `src/app/components/playlist/`; radios in `src/service/radios.ts`, `src/store/radios.store.ts`; play history in `src/store/playHistory.store.ts` and `src/app/hooks/use-play-history.ts`.
- Test helpers: `ios/AonsokuKit/Tests/AonsokuKitTests/TestSupport.swift`, `LibraryServiceTests.swift` (temporary database), `PreferencesTests.swift` (a temporary `PreferencesService`).

#### What to implement

##### LibraryService local edits
- `starredIds()`: ids of every song, album and artist whose `starred` is set, with one query per table.
- `setStarred(songIds:albumIds:artistIds:starred:at:)`: set or clear `starred` (ISO-8601 string of `date`) and `starredAt` (milliseconds) on the matching rows of each table; emit a `dataChanged` event for the tables touched.
- `refreshPlaylist(id:)`: fetch `getPlaylist` once through the sync engine's HTTP client and credentials, upsert the playlist row and its detail (entries), emit `dataChanged(["playlists"])`. Throw when the request fails.
- `removePlaylist(id:)`: delete the playlist row and its detail; emit `dataChanged(["playlists"])`.

##### PinnedHomeStore
- `load()`: read `[PinnedItem]` from `pinned.v1` (ignore undecodable data), keeping order and dropping duplicates.
- `pin`, `unpin`, `toggle`: update `items` (new pins first, no duplicates), save `pinned.v1`, and keep `resolved` in step: unpinning removes the item from `resolved` at once; pinning resolves again in the background.
- `resolve()`: resolve every pin with `repository.cachedAlbum`/`cachedPlaylist` first and the server detail when that is missing and online. Items that cannot be resolved are left out of `resolved` but stay pinned. Sort like the web `sortPinnedHomeItemsByPlayedAt` (most recently played first, never-played last, then by name).

##### FavoritesStore
- `load()`: fill the id sets from `library.starredIds()` at once, then, when `api.starred()` succeeds, replace them with the server's sets. Increment `revision` when the sets change.
- `toggle` and both `setFavorite` variants apply the change to the sets immediately (and increment `revision`), then send `star`/`unstar`. Requests for the same item are serialized: if the user changes an item again while a request is in flight, send the newest wanted state after it finishes and skip intermediate ones. On success update the local library with `setStarred`. On failure restore the last state the server confirmed, increment `revision`, and show `toasts?.show(error:)`.

##### PlaylistsStore
- `loadIfNeeded()` loads once; `reload()` reads `repository.playlists()` into `playlists` with `phase` (`.loading` only while `playlists` is empty; `.failed` keeps the old list).
- `create`: `api.createPlaylist(name:songIds:)`; when the comment is not empty or `isPublic` is true, follow with `updatePlaylist` for those fields. When the server does not return the new playlist (Subsonic below 1.14), find it in `api.playlists()` by name, newest first. Then `library.refreshPlaylist(id:)` (ignore its failure), reload, increment `revision`, and return the playlist with its final fields.
- `update`: `updatePlaylist` with name, comment and public; `refreshPlaylist`; reload; `revision`.
- `delete`: `deletePlaylist`; `library.removePlaylist`; remove it from `playlists`; `revision`.
- `add(songIds:to:)`: read the playlist's current entries (`repository.playlist(id:)`), skip ids already in it and duplicates within the request (keep request order), send only the rest (no request when nothing is left), `refreshPlaylist`, `revision`; return the skipped ids.
- `remove(indexes:from:)`: send the unique indexes sorted ascending, `refreshPlaylist`, reload, `revision`.
- Errors from the server propagate to the caller unchanged; the local state is only changed after the server succeeded.

##### RadioStore
- `load()`: `api.radioStations()` into `stations` in server order, with `phase` like `PlaylistsStore.reload()`.
- `create`, `update`, `delete`: call the API, then reload; errors propagate.

##### ListeningHistoryStore
- Storage: the native play history in `PreferencesService` holds one JSON string per song in Subsonic song shape, newest first (the web and the earlier app wrote the same shape). `load()` decodes entries up to `maxSize` with `SubsonicJSON.song` (skip invalid ones). Writing needs the inverse: add an internal encoder from `Song` to a Subsonic song JSON object in a new file under `Stores/`, covering every field `SubsonicJSON.song` reads, so a round trip keeps the song unchanged.
- `record(_:)`: put the song first (a song already at the front is not duplicated; elsewhere in the list it stays, as on the web), trim to `maxSize`, save. `remove(at:)` and `clear()` update `songs` and the storage (rewrite the stored list when removing one entry). Changing `maxSize` trims on the next change.
- `trackPlayback(song:isPlaying:isRemote:now:)`: port `use-play-history.ts`: accumulate playing time of the current song (pauses do not count, remote control does not count, radio arrives as `song == nil`); when the song changes, record the previous song if it accumulated at least 10 seconds.

##### Tests
Add focused tests (for example `PinnedHomeStoreTests.swift`, `FavoritesStoreTests.swift`, `PlaylistsStoreTests.swift`, `ListeningHistoryStoreTests.swift`, `LibraryEditTests.swift`) with a fake `SubsonicAPI`, a temporary database and a temporary `PreferencesService`: pin ordering and persistence, resolve sorting and missing items, optimistic favorites with success, failure rollback, serialized rapid toggles and local `setStarred`, every playlist operation including skipped ids and the pre-1.14 create path, radio reloads, history recording rules (10-second threshold with pauses, remote and radio ignored), storage round trips, and the four LibraryService methods against seeded rows.

### WP-C: Player

Implement the player store: `PlayerStore`, which drives local playback through the existing native `AudioService` and remote playback through a `RemotePlaybackSource`, plus ReplayGain in `AudioService.setReplayGain(_:)`.

**Files:** `ios/AonsokuKit/Sources/AonsokuKit/Stores/PlayerStore.swift`; in `ios/AonsokuKit/Sources/AonsokuKit/Audio/AudioService.swift` only the body of `setReplayGain(_:)` plus the private state and helpers ReplayGain needs (applying the gain to the player's volume on every load and when the config changes); `Audio/AudioReplayGain.swift` for the gain computation. You may add new source files under `Stores/` and new test files under `ios/AonsokuKit/Tests/AonsokuKitTests/`.

**Note:** `AudioService` emits events and state from its own queues. Never block the main thread waiting for it, and never register a `NotificationCenter` observer for its notifications with `queue: .main` (that deadlocks against its `stateQueue.sync`); hop to the main actor with `Task { @MainActor in ... }` or `DispatchQueue.main.async`.

#### Read first

- `Stores/PlayerStore.swift` and `Model/PlayerModels.swift`: every public member has a doc comment that is the specification.
- `Audio/AudioService.swift`, `Audio/AudioServiceModels.swift`, `Audio/NativeQueueEngine.swift` (`QueueSong`), `Audio/NativeShuffleEngine.swift`, `Audio/AudioReplayGain.swift`: the native queue engine owns the context queue, user queue, shuffle, repeat, history, persistence, scrobbling, sleep timers and system media controls. `PlayerStore` is a thin, observable adapter over it; do not reimplement queue rules that the engine already applies.
- `Stores/LibraryRepository.swift` (albums, playlists, artist songs, `songs(ids:)`), `Stores/SettingsStore.swift` and `Model/SettingsModels.swift` (`PlaybackSettings`, `ReplayGainSettings`), `Stores/LibraryCollectionsStores.swift` (`FavoritesStore`), `Coordination/CoordinationModels.swift` (`CoordinationRemoteCommand`), `Auth/AuthenticationService.swift` (`streamURL(songId:)`, `coverArtURL(id:size:)`).
- The web behavior you mirror: `src/store/player/queue-actions.ts` (queue replacement confirmation: `shouldConfirmQueueReplacement`, play next, add to queue), `src/store/player/playback-actions.ts`, `src/store/player/queue-utils.ts`, `src/store/player/queue-transitions.ts`, `src/player/queue-controller/native-controller.ts` (how the web drives the same native engine through the Capacitor plugin: the exact `AudioService` calls for each action), `src/utils/replayGain.ts`, `src/app/hooks/use-sleep-timer.ts`, `src/store/player/star-actions.ts`.
- Existing tests that exercise `AudioService` without real playback: `ios/AonsokuKit/Tests/AonsokuKitTests/QueueTests.swift`, `ShuffleTests.swift`, `PlaybackLifecycleTests.swift`, `AudioAdapterTests.swift`, `TestSupport.swift`.

#### What to implement

##### Song conversion and the song cache
- `Song` to `QueueSong`: stream URL from `authentication.streamURL(songId:)`, cover art id, artist and album ids, duration, and ReplayGain from `Song.replayGain`. Songs without a stream URL (signed out) are skipped.
- `QueueSong` to `Song` for display: keep a cache of the full `Song` values the store handed to the engine, by id. For queues the engine restored at launch, show songs built from the `QueueSong` at once, then replace them with `repository.songs(ids:)` results when those arrive.

##### Lifecycle
- `start()`: subscribe to `AudioService` events once, adopt `audio.fullState()` (restored queue, position, shuffle, repeat), the system volume and the sleep timer, and keep every local property current from events: `localSong`, `localIsPlaying`, `isBuffering`, `localClock` (sample position, duration and rate on state changes, seeks and at most every few seconds from progress events, not on every event), `localQueue` (rebuild from the engine's queue snapshot on queue events), `localShuffle`, `localRepeatMode`, `localVolume`, `sleepTimer`, `errorMessage`.
- Build `PlayerQueue` from the engine snapshot: `history` = context songs before the current index (oldest first), `current`, `userQueue`, `upNext` = context songs after the current index, `source` from `sourceId` (`QueueSource(encoded:)`) and `sourceName`. Entry `index` values are positions in each tier's full list.
- `clearAll()`: stop, clear the engine's queue and saved state, reset every local property, cancel the sleep timer.

##### Starting playback
- `play(_:startingAt:shuffle:source:sourceName:confirmed:)`: while something is playing and the user queue holds songs that would be lost (the web `shouldConfirmQueueReplacement` rules: protect remaining user-queue songs, excluding the current song while it plays from the user queue; paused playback, empty user queue, resuming the same context and queue navigation do not ask), set `pendingReplacement` and stop unless `confirmed`. Otherwise replace the context queue (`setContextQueue` with source and name), apply shuffle the way `native-controller.ts` does, start at `index`, play. Count the start in `playbackStarts`.
- `play(song:sourceName:confirmed:)`: the same with a one-song context.
- `playAlbum`, `playPlaylist`: load songs through `repository` (local first, offline-safe), then `play` with `.album(id)` / `.playlist(id)` and the name. `playArtist`: every song by the artist (`repository.songs(SongListQuery(scope: .artist(id:name:)), offset: 0, limit: 10_000)`), source `.artist(id)`.
- While `remote` reports a controlled device, these methods send `CoordinationRemoteCommand`s instead (play the album, playlist or the song ids at an index, with shuffle), using the same confirmation rules against the remote queue, and set `pendingReplacement.targetDeviceId`. Read `CoordinationModels.swift` for the command cases.
- `playRadio(_:index:)`: load the station stream (`AudioSource.radio`) with station metadata, set `radio`, clear `localSong`; next and previous move between stations (wrapping). On a load error set `errorMessage` to the error text. Radio is local only.
- `resolveReplacement(_:)`: `.replace` clears the user queue and plays the request; `.playNext` inserts `request.playNextSongs()` after the current song and starts the first of them; `.cancel` drops the request. Ignore a request whose `targetDeviceId` no longer matches the current target.
- `enqueue(_:position:)`: `addToUserQueue` with `"next"` or `"last"`; when nothing is loaded, start playing them instead. Remote: `add_to_queue_next` / `add_to_queue_last` commands with the song ids.

##### Transport, queue and timer
- `togglePlayPause`, `resume`, `pause`, `next`, `previous` (restart after 3 seconds, as the doc says), `seek(to:)`, `toggleShuffle`, `cycleRepeat` (`AudioRepeatMode.next`), `setVolume(_:)` (system volume through `audio.setSystemVolume`; remote: the volume command): route to the engine or, while remote, to `remote.send(...)`; report remote failures in `errorMessage`.
- `play(entry:)` jumps to a row (context index or user-queue position); `playFromHistory(_:)` inserts the song next and starts it; `remove(entries:)` removes rows (context rows rebuild the context without them, keeping the current song; user rows by index); `move(in:from:to:)` converts `List.onMove` offsets of the visible rows to engine indexes (context rows after the current song only, user rows within the user queue); `clearQueue()` clears the user queue and the remaining context, keeping the current song.
- Sleep timer: `setSleepTimer(minutes:)` (countdown, `audio.setSleepTimer(seconds:mode:)`), `setSleepTimerEndOfTrack()`, `cancelSleepTimer()`; `sleepTimer` returns to `.off` when the timer fires (`sleepTimerFired` event).
- `toggleFavoriteCurrent()`: `favorites?.toggle(.song, id:)` for the current song; keep the lock-screen like state in step (`audio.setLikeActive`). Handle the engine's `toggleLike` remote command the same way.

##### ReplayGain (AudioService.setReplayGain)
- Port `src/utils/replayGain.ts`: with a config, the gain for a song is its track or album gain by mode (falling back to the other tag, then `defaultGain`), plus `preAmp`; convert to a linear factor and clamp so `factor * peak <= 1` when the peak is known. Apply it as the player's volume for every load and immediately when the config changes; nil restores unity gain. Store the config thread-safely, as the rest of `AudioService` stores its state.

##### Tests
Add focused tests (for example `PlayerStoreTests.swift`, `ReplayGainTests.swift`) through your seams: queue snapshot to `PlayerQueue` mapping, replacement confirmation rules and every choice, play album/playlist/artist through a fake repository, remote routing through a fake `RemotePlaybackSource`, enqueue, move/remove index conversion, radio next/previous, sleep timer state, the `playbackStarts` counter, restored queues enriched by `songs(ids:)`, and ReplayGain factors (modes, fallbacks, pre-amp, peak clamp).

### WP-D: Lyrics

Implement the lyrics store: `LyricsStore`, which finds lyrics for the playing song from the server, LRCLIB and a custom lyrics server, parses them, caches them, and remembers per-song choices.

**Files:** `ios/AonsokuKit/Sources/AonsokuKit/Stores/LyricsStore.swift`. You may add new source files under `ios/AonsokuKit/Sources/AonsokuKit/Stores/` (for example `LyricsParser.swift`, `LyricsSources.swift`) and new test files under `ios/AonsokuKit/Tests/AonsokuKitTests/`.

#### Read first

- `Stores/LyricsStore.swift` and `Model/LyricsModels.swift`: every public member has a doc comment that is the specification.
- `API/SubsonicAPI.swift` (`lyrics(artist:title:)`, `lyricsBySongId(_:)`), `Data/LibraryService.swift` (`lyrics(songId:)`, `storeLyrics(songId:content:synced:)`), `Model/SettingsModels.swift` (`LyricsSettings`, `PrivacySettings.lrcLibEnabled`), `Preferences/PreferencesService.swift` (`getJSON`/`setJSON`).
- The web behavior you mirror, closely: `src/service/lyrics.ts` (source order, Navidrome structured lyrics, LRCLIB requests and headers, the custom server search and fetch protocol, song keys, candidate keys, caching), `src/utils/lrc-converter.ts` and its tests (LRC parsing, translations and romanization lines), `src/store/player/custom-lyrics-persist.ts` (selections, the 50-song limit), `src/app/components/fullscreen/lyrics.tsx` (how lines, translations and offsets are used). The LRCLIB user agent string is `Aonsoku v<version> (https://github.com/realtvop/aonsoku-reborn)`; read the version from the main bundle's `CFBundleShortVersionString`.

#### What to implement

- `load(for:)`: nil clears to `.idle`. For a song: if the song's selection is disabled, `.disabled`. Otherwise `.loading`, then try sources in `settings.lyrics.sourcePriority` order, skipping disabled ones (LRCLIB when `privacy.lrcLibEnabled` is false; the custom server unless `customServerEnabled` with a URL). A selected custom candidate for this song wins over every source. Prefer synced lyrics when `preferSyncedLyrics` is on (keep looking for a synced result before settling on plain text, as the web does). Navidrome: OpenSubsonic `lyricsBySongId` first (structured, synced, with offsets), then `getLyrics` by artist and title; for LMS (`serverType()` is `lms`) use the web's artist rule. Store successful results in the local lyrics cache (`library.storeLyrics`) and use that cache when offline or when every source fails with a connectivity error. Result: `.loaded(SongLyrics)` or `.unavailable`. Concurrent calls for the same song share one load; a load for an older song never overwrites the state of a newer one. Keep an in-memory cache of recent results by song id.
- Parsing: LRC with multiple time tags per line, `[offset:]`, metadata tags ignored, empty lines kept as gaps the way the web does, line `end` = next line start (last line: the song duration, or start + 5 seconds); translation and romanization lines attached the way `lrc-converter.ts` does; plain text split into unsynced lines. `showTranslation` off drops translations.
- `reload()`: drop the in-memory cache for the current song and load again.
- `searchCandidates(title:artist:)`: the custom server search from the web; empty when the server is not configured; errors propagate.
- `select(_:)`: store the candidate as the song's selection (keeping its offset), then reload. `resetSelection()`: clear the candidate but keep `offset` and `disabled`, then reload. `setDisabled(_:)`: store and update `state` to `.disabled` or reload. `setOffset(_:)`: clamp to `offsetRange`, round to `offsetStep`, store. A selection equal to the default is removed from storage. Storage: `lyrics.selections.v1`, a JSON object keyed by song key, at most `maxRemembered` songs (drop the least recently changed).
- `selection` always reflects the current song.

##### Tests
Add focused tests (for example `LyricsParserTests.swift`, `LyricsStoreTests.swift`): LRC edge cases from the web tests, translations and romanization, source order and skipping, synced preference, the custom server protocol through a URLProtocol stub, LRCLIB request shape, offline cache use, stale-load protection, selections (select, reset, disable, offset clamping and rounding, the 50-song limit, default removal).

### WP-E: Downloads and legacy import

Implement offline downloads and the one-time import of the earlier app's WebView data: `DownloadsStore` and `LegacyWebDataImporter`.

**Files:** `ios/AonsokuKit/Sources/AonsokuKit/Stores/DownloadsStore.swift`, `Migration/LegacyWebDataImporter.swift`, `Data/Repositories/CacheMetaRepository.swift` (new internal queries), and in `Data/LibraryService.swift` only new internal members (for example an internal accessor for the cache index repository and internal helpers to store imported lyrics). You may add new source files under `Stores/` and `Migration/` and new test files under `ios/AonsokuKit/Tests/AonsokuKitTests/`.

**Note:** `AudioService` emits events from its own queues: hop to the main actor with `Task { @MainActor in ... }`; never observe its notifications with `queue: .main`.

#### Read first

- `Stores/DownloadsStore.swift`, `Migration/LegacyWebDataImporter.swift`, `Model/CacheModels.swift`: every public member has a doc comment that is the specification.
- `Audio/AudioService.swift` (download, resolve, delete and clear audio files; `downloadProgress`, `downloadCompleted`, `downloadFailed`, `streamCacheCompleted` events), `Audio/NativeDownloadManager.swift`, `Audio/AudioCacheUtils.swift`, `Data/LibraryService.swift` (covers: `coverSize`, `deleteCover`, `clearCovers`; lyrics), `Data/Repositories/CacheMetaRepository.swift`, `Data/Models/CacheMetaRecord.swift`, `Image/` (the cover cache and how it records cover rows), `Stores/LibraryRepository.swift`, `Stores/LibraryCollectionsStores.swift` (`FavoritesStore`, `PlaylistsStore`), `Model/SettingsModels.swift` (`CacheSettings`, `SmartDownloadRules`), `Stores/NetworkMonitor.swift` (`Connectivity.isMetered`).
- The web behavior you mirror: `src/service/cache/cache-manager.ts` (download album, playlist, artist and songs; markers; removal rules; clear by source; delete items), `src/service/cache/eviction.ts` (LRU eviction over quotas), `src/service/cache/smart-download-engine.ts` (smart rules and their triggers), `src/service/cache/cache-keys.ts` (index keys such as `audio:<songId>`, `album:<id>`, `playlist:<id>`), `src/service/cache/persist-meta.ts`, `src/types/cache.ts`, and for the import: `src/store/library-db.ts` (Dexie `aonsoku-library` schema), `src/store/idb.ts`, `src/service/lyrics.ts` (custom lyrics in `aonsoku-custom-lyrics`), `src/store/player/custom-lyrics-persist.ts`.

#### What to implement

##### DownloadsStore
- Index: every cached audio file, cover and album/playlist marker has a `cacheMeta` row (`key`, item `id`, `type`, `source`, `triggersJson` for smart rules, `sizeBytes`, `cachedAt`, `lastAccessedAt`, `removedFromServer`). Keep an in-memory snapshot of the index for fast `state(of...)` lookups, refreshed when it changes, and increment `revision` on every change.
- `start()`: subscribe to `AudioService` download and stream-cache events once and load the index. `downloadCompleted` writes or upgrades the song's row (explicit or smart as requested); `streamCacheCompleted` writes an `lru` row unless the song already has a row; `downloadFailed` clears progress and shows `toasts?.show(...)` once per batch; progress updates `activeDownloads` (count, song ids, overall progress).
- `state(ofSong:)`: downloading with progress while in flight, else cached with its source and `removedFromServer`, else not cached (a file that no longer exists on disk counts as not cached). `state(ofAlbum:)` / `state(ofPlaylist:)`: cached when the marker exists and every song is cached; downloading with counts while any of its songs is in flight.
- `download(songs:)`, `download(albumId:)`, `download(playlistId:)`, `download(artistId:)`: resolve songs through `repository` (an artist means all of their albums), write album/playlist markers, upgrade existing `lru`/`smart` rows to `explicit` without downloading again, and queue the rest with `audio.downloadAudioFile` (respecting the engine's own concurrency).
- `remove(songIds:)`, `remove(albumId:)`, `remove(playlistId:)`: remove explicit downloads and markers; a song still needed by another downloaded album or playlist, or by a smart rule, stays (as its other source); delete files that nothing keeps.
- `cancelAll()`: cancel queued and running downloads and reset progress.
- `downloadedAlbums()`, `downloadedPlaylists()`, `downloadedSongs()`: from the markers and explicit rows, resolved through the repository's cached details (offline-safe), sorted by name.
- `items(filter:)`: every row with a display name and subtitle resolved from the local library (song title and artist, album name and artist, playlist name; covers by the album or artist that uses them), newest first. `delete(_:)`, `clear(source:)`, `clearAssets()` remove files and rows (`clearAssets` also empties the cover cache). `refreshUsage()` computes `usage` per pool and assets from the index.
- `applySmartRules()`: skipped when disabled or `connectivity.isMetered`; favorite songs (from `favorites`) and the songs of favorite playlists (starred playlists, as on the web) are downloaded as `smart` with their triggers; smart rows whose triggers no longer match are removed (files deleted unless another source keeps them).
- `enforceQuotas()`: evict `lru` rows (oldest access first) over `settings.cache.lruQuota` and cover rows over `assetsQuota`; 0 means unlimited; explicit and smart rows are never evicted.

##### LegacyWebDataImporter
- `run()`: when `isNeeded`, create a hidden `WKWebView` on `WKWebsiteDataStore.default()` whose configuration registers a minimal `WKURLSchemeHandler` for the `capacitor` scheme serving an empty HTML page, load `capacitor://localhost/` (the earlier app's default Capacitor origin; `capacitor.config.ts` sets no custom scheme or hostname; an unregistered custom scheme can get an opaque origin without IndexedDB), and run JavaScript with `callAsyncJavaScript` to read the IndexedDB databases listed in the type's doc comment. Return the rows as JSON. Then write: cache rows into the native `cacheMeta` index (only rows whose file exists natively, mapping fields), lyrics rows into the library lyrics table, and custom lyrics into `lyrics.selections.v1` (merging, newest wins, at most 50). Set `doneKey` only when the read succeeded (an empty or missing database counts as success); on failure return `failed = true` so the next launch retries. Time out after 15 seconds. Never crash when WebKit is unavailable.
- Keep the JavaScript small and robust: open each database by name, read each object store fully, and skip stores that do not exist.

##### Tests
Add focused tests (for example `DownloadsStoreTests.swift`, `CacheEvictionTests.swift`, `LegacyImportTests.swift`): download flows through a fake download seam, source upgrades, removal rules with shared songs, album and playlist states, usage, filters and names, smart rule application and cleanup, metered skip, LRU and cover eviction, and the import's mapping logic (test the JSON-to-row mapping without a WebView).

### WP-F: Cross-device and library sync

Implement the cross-device and library-sync stores: `CoordinationStore` (connection, devices, remote control and handoff over the existing `CoordinationService`), `LibrarySyncStore` (when and how library sync runs), and the cover art phase of library sync (`LibraryService.syncAll(options:)`).

**Files:** `ios/AonsokuKit/Sources/AonsokuKit/Stores/CoordinationStore.swift`, `Stores/LibrarySyncStore.swift`, `Data/LibrarySyncOptions.swift` (the `syncAll(options:)` body), and internal additions to `Data/Sync/SyncEngine.swift` and `Data/LibraryService.swift` needed for the cover art phase. You may add new source files under `Stores/` and new test files under `ios/AonsokuKit/Tests/AonsokuKitTests/`. In particular `Coordination/*.swift` is finished, reviewed code that you call but do not change.

**Note:** Service callbacks arrive on other queues: hop to the main actor with `Task { @MainActor in ... }`; never observe audio notifications with `queue: .main` (that deadlocks against `AudioService.stateQueue.sync`).

#### Read first

- `Stores/CoordinationStore.swift`, `Stores/LibrarySyncStore.swift`, `Data/LibrarySyncOptions.swift`: every public member has a doc comment that is the specification. `CoordinationStore.swift` also defines `DevicePlaybackSummary` and `DeviceGroups`, with the grouping rules.
- `Coordination/CoordinationService.swift` (connect, reconnect, disconnect, forget, delete, devices, control sessions, commands, snapshots, handoff, `observe`), `Coordination/CoordinationModels.swift` (state, devices, snapshots, `CoordinationRemoteCommand`, error codes), `Stores/PlayerStore.swift` (`RemotePlaybackSource`, `RemoteNowPlaying`, `PlaybackClock`), `Model/PlayerModels.swift` (`PlayerQueue`, `QueueEntry`), `Stores/LibraryRepository.swift` (`songs(ids:)` to resolve snapshot songs), `Stores/ToastCenter.swift`.
- `Data/LibraryService.swift`, `Data/Sync/SyncEngine.swift`, `Data/Sync/SyncScheduler.swift`, `Image/` (cover downloads and the cover cache), `Model/SettingsModels.swift` (`CacheSettings.syncCoverArt`, `coverArtConcurrency`, `PlaybackSettings.useAlbumCoverForSongs`), `Stores/NetworkMonitor.swift` (`Connectivity`).
- The web behavior you mirror: `src/coordination/store.ts`, `src/coordination/manager.ts` (or the manager file in `src/coordination/`), `src/app/components/remote-control/` (projection of the controlled device: song, queue, clock, volume), `src/app/components/devices/` or the device panel hooks (search `use-device-playback-models`), `src/app/hooks/use-native-foreground-sync.ts`, `src/app/observers/` (the metadata sync observer and the coordination observer), `src/service/cache/metadata-sync.ts` and `sync-worker-service.ts` (the cover art phase), and the Electron main-process data service's cover art phase in `electron/main/native/data/` (sizes, concurrency, `useAlbumCoverForSongs`).

#### What to implement

##### CoordinationStore
- `start()`: observe the service once; mirror its `state` into `state` on every change; when the device is registered, connect (the service decides when to reconnect). Rebuild `groups` from devices and snapshots with the rules in `DevicePlaybackSummary` and `DeviceGroups` (this device, live devices playing, offline snapshots younger than `offlineExpiry`, hidden), resolving each snapshot's song id through `repository.songs(ids:)` and caching resolved songs. `stop()` stops observing, ends remote control and disconnects.
- `connect(serverUrl:identityUrl:deviceName:)`: save the config and connect through the service; errors propagate. `disconnect()`, `reconnect()`, `forgetDevice()` (ends remote control first), `deleteAccount()`, `refreshDevices()`, `rename`, `revoke`: call the service; refresh devices after rename and revoke.
- Remote control: `control(deviceId:)` begins a control session and requests snapshots; while controlling, build `remoteNowPlaying` from that device's latest snapshot (song resolved through the cache, `PlayerQueue` from the snapshot's context and user queues, `PlaybackClock` from progress, duration, `isPlaying` and the snapshot's `sampledAt` converted to `ProcessInfo.systemUptime`, shuffle, repeat, volume). `stopControlling()` ends the session and clears `remoteNowPlaying`. When the controlled device goes offline or is revoked, stop controlling and toast the web's exit message. `send(_:)` sends through the active control session and waits for the acknowledgement; errors propagate.
- Handoff: `continueHere(from:)` asks the service for a handoff candidate from that device's cached snapshot; `handoffStatus` goes `.inProgress(deviceName:)`, then `.idle` with the web's success toast when the service reports the commit, or `.failed(code:)` with the web's failure toast. A session superseded by another device shows the web's superseded toast. Toast keys are under `settings.crossDevice.toast` in `src/i18n/locales/en.json`.

##### LibrarySyncStore
- `start()`: subscribe to `library` events once. `syncStateChanged` maps to `phase` (tiers `t1`/`t2`/`t3` to `.syncing`, `coverArt` to `.coverArt`, `done` to `.done` and sets `lastSyncedAt`, errors to `.failed(message)`, cancellations to `.cancelled`); `dataChanged` increments `revision` (coalesce bursts). Read `lastSyncedAt` from `library.availability()` at start. Then run the startup sync once per session: a full sync (`syncAll(options:)` with cover art when `settings.cache.syncCoverArt`) when the library has never synced, otherwise an incremental one, unless offline or on a metered network.
- `syncNow()`: full sync with cover art per settings, even on metered networks (the user asked), not offline. `syncIncremental()`: incremental, not offline. `cancel()`: cancel and set `.cancelled`. `handleForeground()`: incremental sync when the last sync finished more than five minutes ago, not offline, not metered, not while syncing. `stop()`: unsubscribe and cancel.
- After a sync finishes with cover art enabled in settings, nothing else is needed: the cover art phase is part of `syncAll(options:)`.

##### Cover art phase (`LibraryService.syncAll(options:)`)
- With `options.coverArt`, after the metadata tiers succeed, download every album cover (and artist and playlist covers, and song covers unless `useAlbumCoverForSongs`), deduplicated by cover art id, skipping covers already cached at the requested size or larger, with at most `concurrency` downloads at once, through the existing cover cache download. Report progress as `syncStateChanged` events with phase `coverArt`, `processedItems` and `totalItems`, then `done`. Cancellation (`cancelSync()`) stops it promptly. Individual download failures are logged and skipped.

##### Tests
Add focused tests (for example `CoordinationStoreTests.swift`, `LibrarySyncStoreTests.swift`, `CoverArtSyncTests.swift`) through your seams: state mirroring, grouping with expiry, remote projection and clock conversion, stop-controlling on offline or revoked devices, handoff status transitions and toasts, connect error propagation; sync phase mapping, startup sync choice (never synced, synced, offline, metered), foreground throttling, `syncNow` on metered networks; cover art deduplication, size skipping, the concurrency limit and cancellation.

## Integration

`AppModel` already creates every store, connects them, and runs the launch,
sign-in and sign-out sequences. Once the packages land, run each flow in the
simulator against a real server:

- **Session:** first launch and session restore; sign in with token and
  password authentication and with a fallback URL; sign out.
- **Browsing:** Home, Library and Search; album, artist, playlist and genre
  screens; offline mode.
- **Playback:** play an album; shuffle; queue edits; Play Next and Add to
  Queue, including the queue-replacement confirmation.
- **Player:** the mini player, Now Playing, lyrics and the queue.
- **Library edits:** favorites, playlist editing and radio stations.
- **Storage and settings:** downloads, the cache manager and every settings
  page.
- **Cross-device:** connect, remote control and handoff.

Fix what you find in the stores or the wiring, keep the UI design, and
commit the fixes separately. To get a server, ask the user to sign in in
the simulator, or ask before downloading a Navidrome image to run one
locally.

Testing the upgrade from the Capacitor build needs the old build on the
simulator, so ask the user first. That upgrade exercises
`SettingsMigration` and `LegacyWebDataImporter`.

## CI, docs and AGENTS.md

- **`build-ios.yml`:** `.github/workflows/build-ios.yml` still builds the
  Capacitor app (`pnpm run build:mobile`, `cap sync ios`,
  `App.xcodeproj`). Change it to:
  1. run the Kit tests, keeping the xcresult upload;
  2. run `node scripts/check-ios-strings.mjs`;
  3. archive `ios/Aonsoku.xcodeproj` (scheme `Aonsoku`, unsigned) with
     `AONSOKU_BUILD_HASH` set to the short commit SHA (the About screen reads
     it from the Info.plist key `AonsokuBuildHash`);
  4. package the unsigned IPA from the archive.

  The runner needs Xcode 26.
- **`create-tag.yml`:** make the same change to the iOS release job in
  `.github/workflows/create-tag.yml`.
- **Capacitor leftovers:** remove what is left of the Capacitor iOS setup.
  Search `capacitor.config.ts`, `package.json`, the scripts and the docs for
  iOS and `cap sync ios`. Leave Android untouched.
- **`AGENTS.md`:** describe the native iOS app wherever the file still says
  Capacitor iOS, and link `docs/ios-native-app.md`. The places to update:
  - the project overview;
  - Multi-Target Build, including the iOS host and `AppServices`
    paragraphs and the `build:mobile` note;
  - Sync Architecture;
  - Cross-Device Coordination;
  - the Multi-Stack Native Playback table and rules;
  - Tooling Notes.
- **Architecture doc:** keep `docs/ios-native-app.md` current with what you
  build.

## Final validation

- The Kit tests, app build, strings check and lint all pass.
- Run every flow under Integration in the simulator, with screenshots of the
  main screens in light and dark mode.
- Delete this file, make sure `docs/ios-native-app.md` and `AGENTS.md` are
  current, and commit.
