# aonsoku-playerd

`aonsoku-playerd` is the desktop audio sidecar foundation for Aonsoku.
Electron can opt into this sidecar from the existing renderer
`PlaybackBackend` facade during dev smoke testing, but the current web/Electron
playback path remains the default fallback.

## Scope

This crate covers the first desktop MVP boundary:

- JSON DTOs aligned with `@aonsoku/audio-contract` for `load`, `play`,
  `pause`, `stop`, and `seek`
- playback events for `playbackStateChanged`, `progress`, `durationChanged`,
  `bufferingChanged`, `ended`, and `error`
- stdio NDJSON framing where each line is one JSON-RPC-style request
- a Rodio-backed native playback backend for MVP desktop stream and
  native-file playback
- a mock playback backend that preserves deterministic protocol tests and
  smoke checks
- shared MVP JSON fixtures under `fixtures/` for Rust and TypeScript contract
  conformance checks
- Electron main-process client plumbing in
  `electron/main/core/audioSidecarManager.ts` for lifecycle, request
  correlation, NDJSON parsing, and audio event fan-out
- an opt-in Electron IPC/preload bridge exposed as `window.api.audioSidecar`
  when Electron dev mode is running with `AONSOKU_PLAYERD_BRIDGE=1`
- a feature-flagged renderer playback adapter that can route the existing
  Electron player facade through `window.api.audioSidecar` for the MVP command
  and event surface

It does not include queue control, cache/download management, scrobbling, remote
control, sleep timer, system volume support, progressive network buffering, or
mobile playback changes.

The Electron bridge and renderer adapter are intentionally dev-only and opt-in.
The current player still uses the existing playback backend unless both the
main-process bridge and the renderer playback flag are enabled.

## Run And Test

From this directory:

```bash
cargo test
cargo build
```

Run the Electron-side client tests from the repository root:

```bash
./node_modules/.bin/vitest run electron/main/core/audioSidecarManager.test.ts electron/main/core/audioSidecarBridge.test.ts
```

Run the optional Electron-to-sidecar smoke test after Rust is available:

```bash
AONSOKU_PLAYERD_SMOKE=1 ./node_modules/.bin/vitest run electron/main/core/audioSidecarManager.test.ts
```

Run the opt-in real Rodio stream smoke test on a desktop with an audio output
device:

```bash
AONSOKU_PLAYERD_REAL_SMOKE_URL="https://server/song.mp3" ./node_modules/.bin/vitest run electron/main/core/audioSidecarManager.test.ts
```

That smoke test drives `load`, `play`, `seek`, `pause`, and `stop` through the
Electron `AudioSidecarManager` and the Rust sidecar.

For slow dev streams, set `AONSOKU_PLAYERD_REQUEST_TIMEOUT_MS` to a larger
positive integer before launching Electron or running the smoke test. The
default request timeout is 10000 ms.

Run a manual stdio smoke test against the deterministic mock backend:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"load-1","method":"load","params":{"source":{"kind":"stream","url":"https://example.test/song.flac","songId":"song-1"},"metadata":{"duration":120},"autoplay":true}}' \
  '{"jsonrpc":"2.0","id":"seek-1","method":"seek","params":{"position":42}}' \
  '{"jsonrpc":"2.0","id":"pause-1","method":"pause"}' \
  | AONSOKU_PLAYERD_BACKEND=mock cargo run --quiet
```

Each output line is either a JSON-RPC-style response:

```json
{"jsonrpc":"2.0","id":"seek-1","result":{}}
```

or an audio event:

```json
{"event":"progress","payload":{"requestId":"seek-1","currentTime":42.0,"duration":120.0,"bufferedTime":120.0}}
```

## Playback Backend Selection

`cargo run` starts the Rodio backend by default. It opens the default desktop
audio output device and supports the current MVP `stream`, `radio`, `blob`, and
`native-file` source shapes. URL sources are fetched into memory before decode;
native files are decoded from disk. This keeps the sidecar small while proving
real desktop playback behind the existing protocol.

Set `AONSOKU_PLAYERD_BACKEND=mock` to run the deterministic mock backend used by
protocol tests and smoke checks.

While the process is running, the sidecar periodically drains backend events and
emits progress updates during playback. When Rodio reports that the active
source has finished, the sidecar emits `playbackStateChanged` with `ended` and
an `ended` event with reason `finished`.

## Electron Dev Harness

Launch Electron in dev mode with the bridge flag enabled:

```bash
AONSOKU_PLAYERD_BRIDGE=1 pnpm run electron:dev
```

When the bridge is available, the renderer installs
`window.aonsokuAudioSidecarDebug` for console-only manual smoke testing. This
does not route normal player playback through the sidecar.

Example console commands:

```js
await window.aonsokuAudioSidecarDebug.smokeStream("https://server/song.mp3", {
  autoplay: true,
  seekTo: 30,
});
await window.aonsokuAudioSidecarDebug.smokeFile(
  "file:///Users/me/Music/song.mp3",
  {
    seekTo: 30,
  },
);
window.aonsokuAudioSidecarDebug.events;
window.aonsokuAudioSidecarDebug.errors;
```

The smoke helpers return `{ events, errors, summary }`. `summary.ok` is true
when the run had no sidecar errors and observed playing, paused, stopped, and
progress events. Check `summary.playbackStates` and `summary.latestProgress` for
a quick manual pass/fail read. The helpers wait briefly for event lines that
arrive after command responses; pass `settleMs` to tune that wait for slow dev
sessions.

Or drive the commands one at a time:

```js
await window.aonsokuAudioSidecarDebug.loadStream("https://server/song.mp3");
await window.aonsokuAudioSidecarDebug.play();
await window.aonsokuAudioSidecarDebug.pause();
await window.aonsokuAudioSidecarDebug.seek(30);
await window.aonsokuAudioSidecarDebug.play();
await window.aonsokuAudioSidecarDebug.stop();
window.aonsokuAudioSidecarDebug.events;
window.aonsokuAudioSidecarDebug.errors;
```

## Feature-Flagged Renderer Playback

The normal Electron player can route the current app-selected track through the
sidecar MVP backend in dev mode. Enable both layers before launching Electron:

```bash
AONSOKU_PLAYERD_BRIDGE=1 VITE_AONSOKU_AUDIO_SIDECAR=1 pnpm run electron:dev
```

For a runtime toggle during manual smoke testing, enable the bridge at launch,
then set the renderer flag and reload:

```js
localStorage.setItem("aonsoku.audioSidecar.playback.enabled", "1");
location.reload();
```

Remove the key or launch without `VITE_AONSOKU_AUDIO_SIDECAR=1` to switch back
to the existing Electron playback path:

```js
localStorage.removeItem("aonsoku.audioSidecar.playback.enabled");
location.reload();
```

With the flag enabled, `src/player/playback/sidecar-backend.ts` maps the
existing app-facing `PlaybackBackend` calls to `window.api.audioSidecar` for
`load`, `play`, `pause`, `stop`, and `seek`. It listens only for
`playbackStateChanged`, `progress`, `durationChanged`, `bufferingChanged`,
`ended`, and `error`. Queue, preload, shuffle, repeat, remote control,
scrobbling, cache/download, sleep timer, system volume, and mobile playback
remain on the existing code paths or are no-ops for this MVP adapter.

## Remaining Integration Work

The sidecar can drive dev-only Electron renderer playback behind a feature flag,
but it is not yet a production playback replacement. Before making it the
default Electron path, the next phase should:

- run the opt-in Rodio stream smoke on a desktop session with a working audio
  output device
- smoke one normal app-selected track with
  `AONSOKU_PLAYERD_BRIDGE=1 VITE_AONSOKU_AUDIO_SIDECAR=1 pnpm run electron:dev`
- add production packaging for the sidecar binary under Electron resources
- replace the current in-memory URL fetch with progressive network buffering if
  large streams or radio latency require it
- keep queue, cache/download, scrobbling, remote control, sleep timer, system
  volume, and mobile playback out of this bridge until their contracts are
  deliberately extended

## Contract Mapping

The Rust protocol mirrors the first playback subset of
`packages/audio-contract/src/index.ts`.

| Rust DTO | TypeScript contract |
| --- | --- |
| `NativeAudioSource` | `NativeAudioSource` |
| `NativeAudioMetadata` | `NativeAudioMetadata` |
| `NativeAudioLoadOptions` | `NativeAudioLoadOptions` |
| `NativeAudioSeekOptions` | `NativeAudioSeekOptions` |
| `NativeAudioPlaybackStateChangedEvent` | `NativeAudioPlaybackStateChangedEvent` |
| `NativeAudioProgressEvent` | `NativeAudioProgressEvent` |
| `NativeAudioDurationChangedEvent` | `NativeAudioDurationChangedEvent` |
| `NativeAudioBufferingChangedEvent` | `NativeAudioBufferingChangedEvent` |
| `NativeAudioEndedEvent` | `NativeAudioEndedEvent` |
| `NativeAudioErrorEvent` | `NativeAudioErrorEvent` |

JSON uses the same camelCase field names and source `kind` values as the
TypeScript contract. Optional fields serialize as omitted fields, matching the
shape a future Electron bridge should pass through to the renderer.

## Framing

Requests are newline-delimited JSON objects with a JSON-RPC-style envelope:

```json
{"jsonrpc":"2.0","id":"play-1","method":"play"}
```

This is not a full JSON-RPC implementation. The sidecar currently uses the
small envelope shape needed by the desktop MVP: `jsonrpc` must be `"2.0"`,
`id` must be a string or integer, `method` must be one of the supported MVP
commands, and `params` must match that command when required. Notifications,
batches, named JSON-RPC error codes, and general-purpose method dispatch are
out of scope.

`id` is copied into the response and used as the fallback event `requestId`.
For `load`, an explicit `params.requestId` wins when present because that field
already exists in `NativeAudioLoadOptions`.

## Fixtures

`fixtures/mvp-contract.json` contains the current command and event surface for
the desktop sidecar MVP. Rust tests parse those fixtures into the sidecar DTOs,
and Vitest checks the same JSON is assignable to the TypeScript
`@aonsoku/audio-contract` payload types. Update this file when the MVP bridge
surface changes.
