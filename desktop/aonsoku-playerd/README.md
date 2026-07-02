# aonsoku-playerd

`aonsoku-playerd` is the desktop audio sidecar foundation for Aonsoku. It is
currently intentionally standalone: Electron does not spawn it yet, and the
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

It does not include a real native audio engine, queue control, cache/download
management, scrobbling, remote control, sleep timer, or system volume support.

## Run And Test

From this directory:

```bash
cargo test
cargo build
```

Run a manual stdio smoke test:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"load-1","method":"load","params":{"source":{"kind":"stream","url":"https://example.test/song.flac","songId":"song-1"},"metadata":{"duration":120},"autoplay":true}}' \
  '{"jsonrpc":"2.0","id":"seek-1","method":"seek","params":{"position":42}}' \
  '{"jsonrpc":"2.0","id":"pause-1","method":"pause"}' \
  | cargo run --quiet
```

Each output line is either a JSON-RPC response:

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

`id` is copied into the response and used as the fallback event `requestId`.
For `load`, an explicit `params.requestId` wins when present because that field
already exists in `NativeAudioLoadOptions`.
