# Android to iOS Native Test Coverage Matrix

This matrix tracks native test parity by behavior and regression risk. It does
not treat raw test-count parity as the goal: Android-only platform contracts
are marked not applicable, and one iOS integration test may cover several
smaller Android helper tests when it exercises the same failure surface.

## Baseline inventory

Inventory date: 2026-10-04.

- Android: 25 test files and 142 `@Test` cases across
  `android/app/src/{test,androidTest}` and
  `capacitor-plugins/capacitor-native/android/src/{test,androidTest}`.
- iOS: 6 XCTest files and 11 `test*` methods in
  `capacitor-plugins/capacitor-native/ios/Tests/AonsokuNativePluginTests`.
- Status legend:
  - **Covered**: iOS verifies the same behavior and failure risk.
  - **Partial**: iOS covers part of the behavior but leaves a material branch
    or integration boundary untested.
  - **Missing**: the behavior applies to iOS and has no meaningful XCTest.
  - **N/A**: Android-specific behavior with no equivalent iOS contract, or
    generated boilerplate with no product behavior.

## Coverage matrix

| Area | Android test inventory | iOS baseline coverage | Status | iOS action / rationale |
| --- | --- | --- | --- | --- |
| App template unit test | `ExampleUnitTest` (1): `addition_isCorrect` | None | N/A | Generated arithmetic smoke test; it protects no Aonsoku behavior. |
| App package instrumentation | `ExampleInstrumentedTest` (1): `useAppContext` | None | N/A | Android package-name contract. iOS bundle/build validity belongs in the App build verification. |
| Debug gesture | `DebugShakeDetectorTest` (6): valid alternating sequence; same-direction rejection; single-spike rejection; slow-stroke expiry; cooldown/retrigger; accelerometer low-pass fallback | iOS receives the OS shake gesture through `AonsokuViewController.motionEnded`; it has no custom sensor detector | N/A | The Android filtering algorithm has no iOS counterpart. App-level debug presentation remains a manual simulator/device check. |
| Android playback service manifest | `PlaybackServiceManifestTest` (4): service resolvability; foreground-media permission; MediaSessionService intent filter; internet permission | iOS has no Android service/manifest contract | N/A | iOS background audio mode and packaging are verified through the App build; runtime background playback still needs device validation. |
| Audio cache naming | `AudioCacheUtilsTest` (2): URL-safe stable cache id; audio MIME extension mapping | `DownloadTests.testCacheIdentityIsPathSafeAndStable`, `testContentTypeSelectsExpectedFileExtension` | Covered | Keep parity when MIME types or on-disk naming change. |
| Remote command allowlist | `AudioPluginRemoteCommandTest` (2): every coordination command accepted; unknown commands rejected | None | Missing | Test the iOS adapter allowlist and dispatch rejection without a Capacitor bridge. |
| Handoff queue decoding | `HandoffPlaybackStateTest` (5): full user/history/shuffle/source restore; empty-context user queue; missing-song rejection; inconsistent current-song rejection; legacy single-song snapshot | `HandoffTests.testHandoffSnapshotPreservesQueueOrderAndSource` covers the valid full snapshot only | Partial | Add empty-context, malformed/fenced queue, and legacy compatibility cases. |
| Capacitor audio payload parsing | `NativeAudioSourceParserTest` (7): stream; native file; radio; blob; null source; metadata fields; null metadata | None | Missing | Exercise the iOS Capacitor adapter's payload decoding while preserving TS event/API shapes. |
| Download manager basics | `NativeDownloadManagerTest` (3): initialization; listener add/remove; inactive cancel/cancel-all | `DownloadTests.testBackgroundSessionIdentifierIsStable` only verifies the identifier | Partial | Verify request creation, cancellation, delegate completion/failure, relaunch completion handling, and no-network fakes. |
| Queue engine | `NativeQueueEngineTest` (5): set/load context; next/previous; manual queue precedence/consumption; reorder/remove; state restoration/full-state | `QueueTests.testUserQueueRunsBeforeRemainingContextAndCanNavigateBack`; `RestorationTests.testPlaybackRepositoryRoundTripsQueueAndProgress` | Partial | Add delegate load/advance semantics, previous restart threshold, reorder/remove/current-index invariants, exhaustion, and full-state compatibility. |
| Scrobble buffer | `NativeScrobbleBufferTest` (9): start/stop; zero-time suppression; pause/resume; ordered entries; clear; selective removal; persistence restart; replacing active tracking; duration retention | None | Missing | Inject a clock and store; verify durable ordering and threshold inputs without sleeps. |
| Shuffle history | `NativeShuffleEngineTest` (3): permutation; recent-history gap avoidance; bounded history | None | Missing | Inject deterministic randomness so assertions verify behavior rather than chance. |
| Source resolution | `NativeSourceResolverTest` (7): explicit cached URI; cache-directory hit; authenticated custom stream; direct HTTP pass-through; radio pass-through without credentials; custom stream rejection without credentials; bitrate/format propagation | None | Missing | Inject file locations and credential lookup; verify cache-first resolution and authenticated URL construction without network. |
| Subsonic authentication | `SubsonicAuthBuilderTest` (5): token salt/hash; encoded password; token query; password query; protocol version parsing contract | None | Missing | Cover both auth modes, percent-safe query values, and version compatibility. |
| Subsonic HTTP URL construction | `SubsonicHttpClientTest` (2): REST path/auth query; existing path query preservation | None | Missing | Inject `URLSession`; test URL/request construction and response/error mapping with `URLProtocol`. |
| Android foreground-service coordination ownership | `AonsokuNativeCoordinationLifecycleTest` (9): attach without/with connection; idempotent attach; detach paths; socket ownership; manual-disconnect state; static attach/detach helpers | iOS has no foreground service, but it has application lifecycle and reconnect ownership | Partial | Mark service attachment mechanics N/A; cover the shared risks: manual disconnect suppresses reconnect, transport failure schedules reconnect, foreground requests a fresh ticket, and shutdown cancels work. |
| Coordination envelopes and snapshots | `AonsokuNativeCoordinationPluginTest` (18): heartbeat shape/version/unique id; hello handshake; target-ready fencing; command ACK; relinquish ACK; handoff failure; playback snapshot mapping/empty state; JSON object valid/malformed/array/empty; ticket URL append/preserve/encode; token-store namespace | Only `HandoffTests.testTargetReadyEnvelopeCarriesFencingState` | Partial | Cover every protocol envelope, JSON rejection, ticket encoding, playback snapshot mapping, and persistent key namespace. |
| Coordination deduplication and sequence | `CoordinationDedupSeqTest` (14): mark/detect; bounded eviction; idempotent mark; clear; monotonic sequence; null sequence; reset; numeric/string/absent sequence extraction; message-id extraction; type extraction | None | Missing | Test bounded dedup and monotonic sequence helpers directly, then one adapter-level duplicate-message regression. |
| Data event contract | `EventEmitterContractTest` (4): `syncStateChanged`; `dataChanged`; terminal immediate flush; intermediate coalesced flush | None | Missing | Inject scheduling and the Capacitor notifier; verify exact event names/payload keys and terminal flushing. |
| Image cache behavior | `ImageCacheUtilsTest` (11): URL-safe/deterministic/distinct ids; JPEG/PNG/WebP/GIF/default/parameterized MIME mapping; known-extension lookup; multi-extension deletion | None | Missing | Inject the cache directory and test lookup/deletion against a temporary file system. |
| Search behavior | `SearchHelperTest` (7): normalized token split; diacritic folding; blank query; empty condition; single/multi-column condition; multi-token AND | `LibraryServiceTests.testTypedArtistQueryFiltersAndPaginatesRepositoryData` covers an end-to-end ASCII filter, starred constraint, sort, and pagination | Partial | Add normalization/diacritic and multi-token repository queries; prefer result behavior over SQL-string assertions. |
| Sync freshness tiers | `SyncTierTest` (4): T1/T2/T3 windows and ordering | None | Missing | Verify freshness boundary decisions with an injected clock, not constants alone. |
| Full-library sync search query | `SyncEngineSearchQueryTest` (3): Navidrome quoted-empty query; Subsonic empty query; unknown-server fallback | None | Missing | Test the outgoing sync request through a fake HTTP client so the assertion protects server interoperability. |
| Native logger | `NativeLoggerTest` (7): level/message retrieval; empty source; per-source cap; multi-source order; clear; timestamp order; independent buckets | None | Missing | Inject time, verify bounded per-source retention and stable global order. |
| Preference play history | `PlayHistoryCodecTest` (3): corrupt/missing decode; prepend/trim; zero-size clear | None | Missing | Test codec plus a temporary `UserDefaults` suite through `PreferencesManager`. |

## iOS-only high-risk surfaces

Android parity does not cover several iOS-specific risks. They are required in
addition to the mapping above:

- `AVPlayer` item replacement, seek/recovery staging, and stale callback
  suppression.
- Background `URLSession` download relaunch and completion-handler ownership.
- `AppServices` singleton wiring and the typed service boundaries exposed to
  SwiftUI and Capacitor.
- `AudioService` persistence flush/restore and event ordering.
- `LibraryService` repository/sync/cache ownership and sync event forwarding.
- `AppLifecycleService` launch/background/foreground/termination routing.
- Capacitor adapter payload and event compatibility for existing TypeScript
  consumers.

## Completion criteria

Parity is complete only when all non-N/A rows are **Covered**, the iOS test
command reports executed XCTest cases (not merely a successful build), the iOS
App builds, and Android native unit tests still pass. Simulator coverage does
not replace device validation for background audio, media controls, protected
data, background transfer relaunch, or real network transitions.
