# aonsoku-playerd

`aonsoku-playerd` is the desktop audio sidecar foundation for Aonsoku. It is
currently intentionally out of the active playback path: Electron has a
testable main-process sidecar manager that can spawn and speak to it, but the
existing web/Electron playback behavior still uses the current
`PlaybackBackend` path.

## Scope

This crate covers the first desktop MVP boundary:

- JSON DTOs aligned with `@aonsoku/audio-contract` for `load`, `play`,
  `pause`, `stop`, and `seek`
- playback events for `playbackStateChanged`, `progress`, `durationChanged`,
  `bufferingChanged`, `ended`, and `error`
- stdio NDJSON framing where each line is one JSON-RPC-style request
- a mock playback backend that proves the command/event lifecycle
- shared MVP JSON fixtures under `fixtures/` for Rust and TypeScript contract
  conformance checks
- Electron main-process client plumbing in
  `electron/main/core/audioSidecarManager.ts` for lifecycle, request
  correlation, NDJSON parsing, and audio event fan-out

It does not include a real native audio engine, queue control, cache/download
management, scrobbling, remote control, sleep timer, system volume support, or
renderer playback routing through the sidecar.

## Run And Test

From this directory:

```bash
cargo test
cargo build
```

Run the Electron-side client tests from the repository root:

```bash
./node_modules/.bin/vitest run electron/main/core/audioSidecarManager.test.ts
```

Run the optional Electron-to-sidecar smoke test after Rust is available:

```bash
AONSOKU_PLAYERD_SMOKE=1 ./node_modules/.bin/vitest run electron/main/core/audioSidecarManager.test.ts
```

Run a manual stdio smoke test:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"load-1","method":"load","params":{"source":{"kind":"stream","url":"https://example.test/song.flac","songId":"song-1"},"metadata":{"duration":120},"autoplay":true}}' \
  '{"jsonrpc":"2.0","id":"seek-1","method":"seek","params":{"position":42}}' \
  '{"jsonrpc":"2.0","id":"pause-1","method":"pause"}' \
  | cargo run --quiet
```

Each output line is either a JSON-RPC-style response:

```json
{"jsonrpc":"2.0","id":"seek-1","result":{}}
```

or an audio event:

```json
{"event":"progress","payload":{"requestId":"seek-1","currentTime":42.0,"duration":120.0,"bufferedTime":120.0}}
```

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
