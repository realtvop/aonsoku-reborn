# Desktop Native Audio libmpv Backend

Aonsoku's Electron native audio path embeds `libmpv` in the Electron main
process through a small Node-API addon. The renderer and preload bridge still
only see `@aonsoku/audio-contract`; no libmpv handle, native addon object, raw
IPC channel, or arbitrary filesystem access is exposed to the renderer.

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
  `AonsokuAudioApi`, cache/download/native-file integration, queue state,
  startup diagnostics, app-quit cleanup, and event forwarding.
- `electron/main/native/audio/engine-factory.ts` creates the default desktop
  playback backend and records structured libmpv diagnostics.
- `electron/main/native/audio/libmpv-engine.ts` maps Aonsoku playback actions
  and contract events onto libmpv commands and observed properties.
- `electron/main/native/audio/libmpv-binding.ts` loads
  `aonsoku_libmpv.node`, validates packaged manifests, configures Windows DLL
  search paths, adapts the binding to `MpvPlayer`, and reports searched paths
  in load errors.
- `electron/main/native/audio/libmpv/src/aonsoku_libmpv.cc` is the Node-API
  addon. It owns libmpv initialization, option setup, command/property calls,
  the blocking `mpv_wait_event` loop, event translation, and destroy cleanup.
- `scripts/native-audio/prepare-libmpv-resources.mjs` copies the addon and
  supplied libmpv runtime files into the Forge resource layout.
- `scripts/native-audio/verify-libmpv-package.mjs` checks Forge/resource/icon
  packaging assumptions and validates the native-audio manifest.

The old external mpv process backend has been removed. There is no child
process, JSON IPC socket/named pipe, or external `mpv` binary fallback in the
main playback path.

## Contract Behavior

`NativeAudioService` still exposes the shared `@aonsoku/audio-contract`
surface. These event names are unchanged: `playbackStateChanged`, `progress`,
`durationChanged`, `bufferingChanged`, `ended`, `error`, cache/download events,
remote command events, system volume events, queue events, scrobble events, and
sleep timer events.

`LibMpvAudioEngine` observes these libmpv properties:

- `time-pos` -> `progress`
- `duration` -> `durationChanged` and `progress`
- `pause` -> `playbackStateChanged`
- `paused-for-cache` -> `bufferingChanged`
- `cache-buffering-state` -> `bufferingChanged`

libmpv file events map to existing contract semantics:

- `start-file` -> loading + buffering
- `file-loaded` -> playing/paused + progress
- `playback-restart` -> buffering false
- `end-file` with `eof` -> ended/finished
- `end-file` with `error` -> `mpv-playback-error`
- explicit `stop`/`clear` suppress libmpv's internal stop event when the
  service already emitted the intended Aonsoku event

`load`, `play`, `pause`, `stop`, `seek`, `clear`, duration/position updates,
buffering, ended, errors, metadata title updates, native-file playback,
Subsonic streams, radio URLs, queue transitions, system-volume parity, and
download/cache operations all flow through this boundary.

## Loading Strategy

The loader searches for `aonsoku_libmpv.node` in this order:

1. `AONSOKU_LIBMPV_ADDON_PATH`
2. `process.resourcesPath/native-audio/<platform>-<arch>/aonsoku_libmpv.node`
3. `resources/native-audio/<platform>-<arch>/aonsoku_libmpv.node`
4. `electron/main/native/audio/libmpv/build/Release/aonsoku_libmpv.node`

Development normally uses the source-build path. Packaged apps use
`process.resourcesPath`, which Electron Forge fills from `resources/` through
`extraResource`.

Production packages must not rely on a developer machine's global
mpv/libmpv installation as the only runtime condition. Put the addon, libmpv
dynamic library, and required runtime dependencies under:

```text
resources/native-audio/<platform>-<arch>/
  aonsoku_libmpv.node
  manifest.json
  libmpv dynamic library
  libmpv runtime dependencies
```

The runtime manifest lists `requiredFiles`. At startup the loader validates the
manifest before requiring the addon. On Windows the runtime directory is
prepended to `PATH` before loading the addon so DLLs next to the addon are
visible. On macOS the addon is linked with `@loader_path` runpath. On Linux it
is linked with `$ORIGIN` rpath. These settings allow bundled dynamic libraries
next to the addon to be resolved by the platform loader.

## Building

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

Windows builds need `mpv.lib`, libmpv headers, and matching runtime DLLs:

```powershell
$env:AONSOKU_LIBMPV_INCLUDE_DIR = "C:\mpv\include"
$env:AONSOKU_LIBMPV_LIB_DIR = "C:\mpv\lib"
$env:AONSOKU_LIBMPV_LIBRARY = "mpv.lib"
pnpm native-audio:build
pnpm native-audio:smoke
```

Useful environment variables:

- `AONSOKU_LIBMPV_INCLUDE_DIR`: directory containing `mpv/client.h`.
- `AONSOKU_LIBMPV_LIB_DIR`: directory containing the libmpv dynamic/import
  library.
- `AONSOKU_LIBMPV_LIBRARY`: linker library name, defaulting to `-lmpv` on
  macOS/Linux and `mpv.lib` on Windows.
- `AONSOKU_LIBMPV_ADDON_PATH`: explicit addon path for runtime loading or
  smoke checks.
- `AONSOKU_LIBMPV_PLATFORM` / `AONSOKU_LIBMPV_ARCH` / `ARCH`: resource target
  selection for prepare/verify scripts.

The smoke check initializes libmpv with `ao=null`, generates a temporary WAV,
then exercises load, pause, resume, seek, stop, and destroy.

## Resource Preparation

Prepare a current-platform resource bundle:

```bash
pnpm native-audio:prepare -- --runtime-dir /path/to/libmpv/runtime
pnpm native-audio:smoke:packaged
pnpm native-audio:verify-package
```

`--runtime-dir` copies every platform runtime library in the directory:

- macOS: `*.dylib`
- Windows: `*.dll`
- Linux: `*.so`, `*.so.N`, `*.so.N.M`

You can pass exact files instead:

```bash
pnpm native-audio:prepare -- \
  --lib /path/to/libmpv.2.dylib \
  --lib /path/to/libavcodec.dylib
```

Release jobs should make missing runtime libraries fatal:

```bash
pnpm native-audio:prepare -- --runtime-dir /runtime --require-runtime-libs
AONSOKU_REQUIRE_NATIVE_AUDIO_RESOURCES=1 pnpm native-audio:verify-package
```

`resources/native-audio/*/` is ignored by git so local binary bundles are not
committed accidentally. The release pipeline is responsible for preparing the
right bundle for each platform/arch before `make` or `publish`.

## Platform Notes

macOS:

- Build the addon on the target architecture or set `ARCH`.
- Bundle `libmpv` and every dylib it needs in the native-audio resource
  directory.
- The addon has `@loader_path` in its runpath. Release assets should use dylib
  install names that resolve through the bundled directory. If copied Homebrew
  dylibs retain absolute `/opt/homebrew` install names, rewrite them during the
  release asset preparation step before signing/notarization.

Windows:

- Build with headers/import library matching the runtime DLL set.
- Ship `mpv-*.dll` and dependency DLLs next to `aonsoku_libmpv.node`.
- The loader prepends that directory to `PATH` before requiring the addon.

Linux:

- Build on a compatible distro baseline for the intended DEB/RPM/AppImage
  target.
- Bundle compatible `.so` files next to the addon or intentionally rely on
  distro `libmpv` packages. Release builds that rely on distro packages should
  document that dependency in the maker metadata.
- The addon has `$ORIGIN` rpath for bundled `.so` resolution.

## Forge Packaging

Forge uses `asar: true` for app code and `extraResource: ["./resources"]` for
runtime assets. The native addon and libmpv runtime files live outside
`app.asar` under Electron resources, so they are loadable by Node and the
platform dynamic loader.

The custom Forge `ignore` keeps these required inputs:

- `package.json`
- `out/` from `electron-vite`
- `resources/` including icons, taskbar/tray assets, and native-audio bundles

It excludes source directories and `node_modules` from app packaging. The
Node-API addon is not rebuilt by Forge; build it with `pnpm native-audio:build`
and copy it with `pnpm native-audio:prepare`.

In Electron development, the loader prefers the freshly built source addon
over `resources/native-audio`, so an older prepared resource cannot shadow a
new `pnpm native-audio:build` result. Packaged applications continue to load
the addon from `resources/native-audio` first. Older prepared addons that do
not expose the optional system-media-session methods remain playback
compatible; they simply skip native media-session projection until refreshed.

`build:unpack` runs non-strict `pnpm native-audio:verify-package` before the
Electron build so development builds still work and print warnings when local
native-audio binaries are incomplete.

`make`, `publish`, and platform package scripts run strict verification before
Electron build/make:

```bash
pnpm native-audio:verify-package:strict
```

Strict verification fails if the target `resources/native-audio/<platform>-<arch>`
directory, addon, manifest, or runtime libraries are missing. This prevents
release packages from depending only on global libmpv.

## Startup Diagnostics

Electron creates `NativeAudioService` during main-process IPC setup. The
service performs startup availability checks and replays any startup failure to
renderer listeners through the existing `error` event.

Common codes:

- `libmpv-addon-unavailable`: addon missing, ABI mismatch, or `require()` /
  dynamic loader failure.
- `libmpv-runtime-incomplete`: packaged manifest references missing runtime
  files.
- `libmpv-unavailable`: player creation failed.
- `mpv-init-failed`: `mpv_create` or `mpv_initialize` failed.
- `mpv-observer-failed`: one of the required property observers failed.
- `mpv-command-failed`: a libmpv command failed.
- `mpv-property-failed`: a libmpv property update failed.
- `mpv-playback-error`: libmpv reported playback failure for the current file.

Cache, download, and native-file storage APIs remain usable when the playback
backend is unavailable. Playback methods reject and emit clear `error` events
instead of failing silently.

## Verification

Focused checks:

```bash
pnpm native-audio:build
pnpm native-audio:smoke
pnpm native-audio:prepare
pnpm native-audio:smoke:packaged
pnpm native-audio:verify-package
pnpm native-audio:verify-package:strict
pnpm run build:unpack
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

Release CI should run the focused checks on every target platform/arch with a
prepared native-audio resource directory and strict verification enabled.

## Known Limitations

- The prepare script copies explicit files or whole runtime directories; it
  does not crawl dependency graphs with `otool`, `ldd`, or Windows SDK tools.
  Release jobs must assemble a complete runtime directory before calling it.
- macOS dylib install-name rewriting and code signing/notarization are release
  pipeline responsibilities.
- Linux distribution targets may choose between bundled `.so` files and
  distro package dependencies; keep maker metadata and release notes aligned
  with that choice.
