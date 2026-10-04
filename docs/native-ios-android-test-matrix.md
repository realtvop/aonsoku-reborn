# Android to iOS Native Test Coverage Matrix

This matrix tracks native parity by behavior and regression risk, not by raw
test count. Android-only contracts are marked not applicable. An iOS
integration test may cover several Android helper tests when it exercises the
same failure surface through the real service boundary.

## Inventory

Inventory date: 2026-10-04.

- Android: 25 Kotlin/Java test files and 142 `@Test` cases across
  `android/app/src/{test,androidTest}` and
  `capacitor-plugins/capacitor-native/android/src/{test,androidTest}`.
- iOS before this parity pass: 6 XCTest files and 11 `test*` methods.
- iOS after this parity pass: 20 XCTest files and 85 `test*` methods in
  `capacitor-plugins/capacitor-native/ios/Tests/AonsokuNativePluginTests`.
- Status legend:
  - **Covered**: iOS verifies the same behavior and regression risk.
  - **N/A**: the Android behavior has no iOS equivalent or is generated
    boilerplate without Aonsoku product behavior.

## Coverage matrix

| Area | Android test inventory | iOS final evidence | Status |
| --- | --- | --- | --- |
| App template unit test | `ExampleUnitTest` (1): generated arithmetic smoke test | No equivalent; it protects no Aonsoku behavior | N/A |
| App package instrumentation | `ExampleInstrumentedTest` (1): Android package context | iOS bundle and host validity are covered by the App build | N/A |
| Debug gesture | `DebugShakeDetectorTest` (6): sensor filtering, expiry, cooldown, fallback | iOS uses the OS shake gesture and has no custom detector algorithm | N/A |
| Playback service manifest | `PlaybackServiceManifestTest` (4): service, permissions, intent filter | iOS has no Android service/manifest contract; background modes are an App packaging/device concern | N/A |
| Audio cache naming | `AudioCacheUtilsTest` (2): stable safe id and MIME extension | `DownloadTests`: cache identity and content-type extension behavior | Covered |
| Remote command allowlist | `AudioPluginRemoteCommandTest` (2): supported and rejected commands | `AudioAdapterTests`: exact coordination allowlist, rejection, selected IDs and positions | Covered |
| Handoff queue decoding | `HandoffPlaybackStateTest` (5): full, user-only, malformed, inconsistent and legacy snapshots | `HandoffTests` (5) plus `NativeIntegrationTests`: decode compatibility, fencing, injected-library resolution, missing-song rejection and queue restoration | Covered |
| Capacitor audio payload parsing | `NativeAudioSourceParserTest` (7): all source kinds and metadata/null handling | `AudioAdapterTests` (5): all source kinds, invalid payloads, numeric metadata and command payloads | Covered |
| Downloads and cancellation | `NativeDownloadManagerTest` (3): initialization, listener lifecycle and inactive cancellation | `DownloadTests` (8): auth/transcoding URL, missing credentials, active cancel/cancel-all, completion file and metadata finalization, stable background identifier and relaunch completion ownership, all without real network | Covered |
| Queue engine | `NativeQueueEngineTest` (5): set/load, navigation, manual queue, edits and restore | `QueueTests` (6), `RestorationTests` and `NativeIntegrationTests`: delegate load/advance, manual precedence, repeat/exhaustion, current-song-preserving reorder, persistence and adapter-compatible full state | Covered |
| Scrobble buffer | `NativeScrobbleBufferTest` (9): timing, pause/resume, persistence, ordering and mutations | `ScrobbleTests` (6): injected clock/store, zero-time suppression, pause exclusion, duration retention, ordered durable mutations and 50%/240-second eligibility | Covered |
| Shuffle history | `NativeShuffleEngineTest` (3): permutation, recent-gap avoidance and bounds | `ShuffleTests` (3): deterministic randomness, permutation, history avoidance/deduplication and bounds | Covered |
| Source resolution | `NativeSourceResolverTest` (7): cache-first, direct URLs, credentials and transcode options | `SourceResolverTests` (5): injected file system/credentials/clock, cache-first lookup, passthrough, rejection, credential invalidation and option preservation | Covered |
| Subsonic authentication | `SubsonicAuthBuilderTest` (5): token/hash, encoded password, query modes and version | `AuthenticationTests` (4): token salt/hash, encoded password, mutually exclusive query modes and numeric version parsing | Covered |
| Subsonic HTTP | `SubsonicHttpClientTest` (2): REST/auth URL and existing query | `HTTPClientTests` (3): injected `URLSession`/`URLProtocol`, URL preservation, count/payload parsing and auth failure mapping | Covered |
| Coordination lifecycle and reconnect | `AonsokuNativeCoordinationLifecycleTest` (9): Android service/socket ownership and disconnect paths | Android foreground-service attachment is platform-only; shared risks are covered by `CoordinationTests.testReconnectPolicyBacksOffCapsAndStopsForManualOrBackgroundState`, `LifecycleTests` and AppServices integration | Covered |
| Coordination envelopes and snapshots | `AonsokuNativeCoordinationPluginTest` (18): hello/heartbeat/ACK/handoff, snapshots, JSON and ticket URL | `CoordinationTests` (11) and `HandoffTests`: protocol shapes, fencing data, empty snapshot rejection, JSON rejection and reserved-character ticket encoding | Covered |
| Coordination deduplication and sequence | `CoordinationDedupSeqTest` (14): bounded idempotence, sequence and extraction | `CoordinationTests`: bounded eviction/idempotence, clear, monotonic/reset sequence and numeric/string/absent extraction | Covered |
| Data event contract | `EventEmitterContractTest` (4): exact events, terminal flush and coalescing | `EventEmitterTests` (3): public event names/payloads, terminal immediate flush and intermediate coalescing | Covered |
| Image cache behavior | `ImageCacheUtilsTest` (11): ids, MIME mapping, lookup and deletion | `ImageCacheTests` (3): stable/distinct safe ids, compatible extensions, known-extension lookup and multi-extension deletion | Covered |
| Search behavior | `SearchHelperTest` (7): normalization, tokenization and AND conditions | `SearchAndSyncTests` plus `LibraryServiceTests`: width/case/diacritic normalization, multi-token repository results, filters, sorting and pagination | Covered |
| Sync freshness tiers | `SyncTierTest` (4): windows and ordering | `SearchAndSyncTests.testSyncFreshnessUsesStrictBoundaryAndHandlesClockSkew`: strict edge behavior for every tier plus ordering | Covered |
| Full-library search query | `SyncEngineSearchQueryTest` (3): Navidrome quoted-empty and Subsonic/fallback empty query | `SearchAndSyncTests.testFullLibrarySearchQueryMatchesServerDialect`: the same server interoperability decisions used by `SyncEngine` | Covered |
| Native logger | `NativeLoggerTest` (7): content, cap, ordering, sources and clear | `NativeLoggerTests` (3): injected time, per-source caps, cross-source ordering, levels/messages and clear | Covered |
| Preference play history | `PlayHistoryCodecTest` (3): corrupt/missing, prepend/trim and zero-size clear | `PreferencesTests`: database-backed newest-first persistence, limit, trim and zero-size clear; typed preferences also round-trip through an injected database | Covered |

## iOS-specific risk coverage

Parity also includes iOS risks with no direct Android test counterpart:

- `DependencyBoundaryTests` injects the AVPlayer factory and verifies real
  player construction; `AudioService` teardown removes observers safely even
  when the service was loaded before `start()`.
- `RestorationTests` drives seek retries, reload escalation, exhaustion,
  and success cancellation with an injected scheduler.
- `DownloadTests` verifies background `URLSession` relaunch ownership,
  cancellation, cache finalization and metadata without network access.
- `NativeIntegrationTests` covers the `AppServices` service graph,
  `AudioService` queue event/persistence/restore path, handoff through the
  injected library database, `LibraryService` initialization/query/lyrics,
  `AppLifecycleService` routing, and both audio/data Capacitor payload shapes.
- `LifecycleTests` verifies idempotent launch/background/foreground/terminate
  routing and background transfer completion ownership.

## Verification contract and device-only remainder

`./scripts/test-ios-native.sh` writes an `.xcresult`, parses its test summary,
and fails if zero XCTest cases ran, any test failed, or no requested simulator
is available. `IOS_SIMULATOR_ID=<uuid>` selects a simulator and
`IOS_TEST_RESULT_BUNDLE=<path>` preserves the result bundle for CI artifacts.

Simulator parity does not replace real-device validation for background audio
continuity, lock-screen/Control Center commands, protected-data transitions,
OS relaunch of a background transfer after process termination, audio-route
changes/interruption recovery, and connectivity changes involving a real
Subsonic and coordination server.
