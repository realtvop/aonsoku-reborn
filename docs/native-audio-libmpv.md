# Desktop Native Audio libmpv Backend

Aonsoku's Electron native audio path embeds `libmpv` in the Electron main
process through a small Node-API addon. The renderer and preload bridge still
only see `@aonsoku/audio-contract`; no libmpv handle, raw IPC channel, or
filesystem access is exposed to the renderer.

## Architecture

```text
renderer
  -> electron/preload/native-audio.ts
  -> electron/main/native/audio/ipc.ts
  -> NativeAudioService
  -> DesktopAudioEngine
  -> LibMpvAudioEngine
  -> MpvPlayer
  -> aonsoku_libmpv.node
  -> libmpv
```

Key files:

- `electron/main/native/audio/service.ts` owns the desktop implementation of
  `AonsokuAudioApi`, cache/download/native-file integration, queue state, and
  event forwarding.
- `electron/main/native/audio/engine-factory.ts` creates the default desktop
  playback backend. If the addon or dynamic library cannot be loaded it returns
  an unavailable backend that fails playback calls with `libmpv-unavailable`
  while leaving cache/download APIs usable.
- `electron/main/native/audio/libmpv-engine.ts` maps Aonsoku playback actions
  and contract events onto libmpv commands and observed properties.
- `electron/main/native/audio/mpv-player.ts` defines the low-level player
  boundary used by tests and the native binding adapter.
- `electron/main/native/audio/libmpv-binding.ts` loads
  `aonsoku_libmpv.node`, adapts it to `MpvPlayer`, and documents searched
  runtime paths in load errors.
- `electron/main/native/audio/libmpv/src/aonsoku_libmpv.cc` is the Node-API
  addon. It owns libmpv initialization, option setup, command/property calls,
  the blocking `mpv_wait_event` loop, event translation, and destroy cleanup.

The old external mpv process backend has been removed. There is no child
process, JSON IPC socket/named pipe, or external `mpv` binary fallback in the
main playback path.

## Runtime Behavior

`LibMpvAudioEngine` observes these libmpv properties:

- `time-pos` -> `progress`
- `duration` -> `durationChanged` and `progress`
- `pause` -> `playbackStateChanged`
- `paused-for-cache` -> `bufferingChanged`
- `cache-buffering-state` -> `bufferingChanged`

libmpv file events are mapped to the existing contract semantics:

- `start-file` -> loading + buffering
- `file-loaded` -> playing/paused + progress
- `playback-restart` -> buffering false
- `end-file` with `eof` -> ended/finished
- `end-file` with `error` -> `mpv-playback-error`
- explicit `stop`/`clear` suppress libmpv's internal stop event when the
  service already emitted the intended Aonsoku event

`load`, `play`, `pause`, `stop`, `seek`, `clear`, duration/position updates,
buffering, ended, errors, metadata title updates, native-file playback,
Subsonic streams, and radio URLs all flow through the same backend boundary.

## Development

Install libmpv development files before building the addon.

macOS with Homebrew:

```bash
brew install mpv
pnpm native-audio:build
pnpm native-audio:smoke
```

Linux package names vary by distribution. Debian/Ubuntu usually provide
headers and runtime libraries through:

```bash
sudo apt install libmpv-dev
pnpm native-audio:build
pnpm native-audio:smoke
```

Windows builds need `mpv.lib`, libmpv headers, and matching runtime DLLs. Set
these when the defaults do not match the local install:

```powershell
$env:AONSOKU_LIBMPV_INCLUDE_DIR = "C:\mpv\include"
$env:AONSOKU_LIBMPV_LIB_DIR = "C:\mpv\lib"
$env:AONSOKU_LIBMPV_LIBRARY = "mpv.lib"
pnpm native-audio:build
pnpm native-audio:smoke
```

Useful environment variables:

- `AONSOKU_LIBMPV_INCLUDE_DIR` points at a directory containing
  `mpv/client.h`.
- `AONSOKU_LIBMPV_LIB_DIR` points at the directory containing the libmpv
  dynamic/import library.
- `AONSOKU_LIBMPV_LIBRARY` overrides the linker library name, defaulting to
  `-lmpv` on macOS/Linux and `mpv.lib` on Windows.
- `AONSOKU_LIBMPV_ADDON_PATH` points the runtime loader or smoke check at a
  specific `.node` file.

The smoke check loads the compiled addon, initializes libmpv with `ao=null`,
generates a short temporary WAV fixture, runs `loadfile`, waits for
`file-loaded`, stops playback, and destroys the handle.

## Packaging

The loader searches for `aonsoku_libmpv.node` in this order:

1. `AONSOKU_LIBMPV_ADDON_PATH`
2. `process.resourcesPath/native-audio/<platform>-<arch>/aonsoku_libmpv.node`
3. `resources/native-audio/<platform>-<arch>/aonsoku_libmpv.node`
4. `electron/main/native/audio/libmpv/build/Release/aonsoku_libmpv.node`

Electron Forge already packages `resources/` as extra resources. Production
packages should place the addon under:

```text
resources/native-audio/<platform>-<arch>/aonsoku_libmpv.node
```

The libmpv dynamic library and its codec/audio dependencies must also be
resolvable by the platform dynamic loader:

- macOS: bundle/sign/notarize dylibs with the app or require a compatible
  system/Homebrew install during development. TODO: add a release packaging
  script that copies and rewrites dylib install names for app distribution.
- Windows: ship `mpv-*.dll`/dependency DLLs next to the addon or another
  loader-visible directory. TODO: add a Windows packaging manifest once the
  project has a checked-in mpv SDK layout.
- Linux: rely on distro `libmpv` packages for now, or ship compatible `.so`
  files with rpath/loader configuration. TODO: decide per maker target whether
  to depend on system `libmpv` or vendor it.

If any required addon or library is missing, Electron starts normally but
desktop playback fails with a visible `libmpv-unavailable` error. The failure
is not silent, and cache/download/native-file storage APIs remain available.

## Verification

Focused checks:

```bash
pnpm native-audio:build
pnpm native-audio:smoke
pnpm exec vitest run \
  electron/main/native/audio/engine-factory.test.ts \
  electron/main/native/audio/libmpv-engine.test.ts \
  electron/main/native/audio/libmpv-binding.test.ts \
  electron/main/native/audio/service.test.ts \
  electron/main/native/audio/ipc.test.ts \
  electron/main/native/audio/ipc-binding.test.ts \
  electron/preload/native-audio.test.ts \
  src/native/audio/contract-drift.test.ts
```

Cache/native-file regression checks:

```bash
pnpm exec vitest run \
  src/service/cache/native-cache-adapter.test.ts \
  src/service/cache/audio-source/index.test.ts \
  src/native/audio/facade.test.ts
```
