#!/usr/bin/env node
/**
 * Collect the libmpv runtime .so dependency closure for Linux and stage it
 * for `prepare-libmpv-resources.mjs`.
 *
 * This is the Linux counterpart to `collect-runtime-darwin.mjs`. It walks the
 * `ldd` dependency tree of the audio-only libmpv built by
 * `build-libmpv-linux.mjs`, copies every non-base-system .so into a flat
 * staging directory, and uses `patchelf` to set `$ORIGIN` rpath so the
 * bundled libs resolve each other without touching system paths.
 *
 * The addon (`aonsoku_libmpv.node`) is already linked with `$ORIGIN` rpath
 * (see `binding.gyp`), so it will find `libmpv.so` placed next to it. The
 * bundled libmpv and each of its bundled dependencies get `$ORIGIN` rpath
 * too, making the flat directory self-consistent.
 *
 * Only truly universal base-system libraries are excluded (libc, libm, the
 * dynamic loader, etc.). Everything else — FFmpeg, libass, freetype,
 * fontconfig, PulseAudio client, D-Bus, libstdc++, libgcc_s — is bundled so
 * the package works on any glibc-compatible Linux of the same arch without
 * requiring the user to install development/runtime packages.
 *
 * Requires `patchelf` on PATH (`apt install patchelf`).
 *
 * Usage:
 *   node scripts/native-audio/ci/collect-runtime-linux.mjs \
 *     --root ./.native-audio-build/install/lib/libmpv.so.2 \
 *     --staging ./.native-audio-staging \
 *     [--addon electron/main/native/audio/libmpv/build/Release/aonsoku_libmpv.node]
 */
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  realpathSync,
  rmSync,
} from "node:fs";
import path from "node:path";

const args = parseArgs(process.argv.slice(2));
const rootLib = path.resolve(args.root ?? fail("--root is required"));
const staging = path.resolve(args.staging ?? "./.native-audio-staging");
const addon = args.addon ? path.resolve(args.addon) : null;

if (!existsSync(rootLib)) fail(`Root library not found: ${rootLib}`);

rmSync(staging, { recursive: true, force: true });
mkdirSync(staging, { recursive: true });

console.log(`native-audio: root lib  ${rootLib}`);
console.log(`native-audio: staging  ${staging}`);

// 1. Walk the ldd closure, collecting (soname → resolved-path) for every
//    non-base-system .so. The root lib itself is included.
const closure = collectClosure(rootLib);
if (closure.length === 0) fail("No libraries found to bundle.");

// 2. Copy each library into the staging directory using its soname as the
//    filename, then set $ORIGIN rpath via patchelf.
const bundled = [];
for (const { soname, resolved } of closure) {
  const dest = path.join(staging, soname);
  copyFileSync(resolved, dest);
  patchelfRpath(dest);
  bundled.push(soname);
  console.log(`native-audio: bundled ${soname}`);
}

// 3. The addon already has $ORIGIN rpath from binding.gyp; no patching needed.
if (addon && existsSync(addon)) {
  console.log(`native-audio: addon ${addon} (rpath already $ORIGIN)`);
}

console.log(
  JSON.stringify(
    {
      ok: true,
      staging,
      bundled,
    },
    null,
    2,
  ),
);

/**
 * BFS through the ldd dependency tree of `root`, returning an ordered list
 * of { soname, resolved } for the root and every non-base-system dependency.
 */
function collectClosure(root) {
  const visited = new Set();
  const queue = [{ lib: root, soname: path.basename(root) }];
  const result = [];

  while (queue.length > 0) {
    const { lib, soname } = queue.shift();
    const resolved = realpathSafe(lib);
    if (visited.has(resolved)) continue;
    visited.add(resolved);

    if (!isBaseSystemLib(soname)) {
      result.push({ soname, resolved });
    }

    for (const dep of lddDependencies(lib)) {
      if (dep.path && !isBaseSystemLib(dep.soname)) {
        const depResolved = realpathSafe(dep.path);
        if (!visited.has(depResolved) && existsSync(dep.path)) {
          queue.push({ lib: dep.path, soname: dep.soname });
        }
      }
    }
  }

  return result;
}

/**
 * Parse `ldd <lib>` output and return an array of { soname, path }.
 * ldd output format:
 *   \t<soname> => <path> (<address>)
 *   \t<soname> (<address>)               ← vdso, no path
 *   \t/path/to/ld-linux.so (<address>)   ← loader, no soname
 */
function lddDependencies(lib) {
  const result = spawnSync("ldd", [lib], { encoding: "utf8" });
  if (result.status !== 0) {
    // Some libs (e.g. static or stub) may produce a warning but still exit 0.
    // A non-zero exit usually means the lib is not dynamically linked.
    return [];
  }

  const deps = [];
  for (const line of result.stdout.split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    const arrowMatch = /^\s*(?<soname>\S+)\s+=>\s+(?<path>\S+)/u.exec(trimmed);
    if (arrowMatch) {
      deps.push({
        soname: arrowMatch.groups.soname,
        path: arrowMatch.groups.path,
      });
      continue;
    }

    // Lines without "=>" (linux-vdso, ld-linux) — skip.
  }

  return deps;
}

/**
 * Base-system libraries that are guaranteed to exist on every glibc-based
 * Linux. These are never bundled.
 */
const BASE_SYSTEM_LIBS = new Set([
  "libc.so.6",
  "libc.so.17", // musl (shouldn't appear on glibc CI)
  "libm.so.6",
  "libdl.so.2",
  "libpthread.so.0",
  "librt.so.1",
  "libresolv.so.2",
  "libutil.so.1",
  "linux-vdso.so.1",
  "linux-gate.so.1",
  "ld-linux-x86-64.so.2",
  "ld-linux-aarch64.so.1",
  "ld-linux.so.2",
  "libBrokenLocale.so.1",
  "libanl.so.1",
  "libmemusage.so",
  "libSegFault.so",
]);

function isBaseSystemLib(soname) {
  // Exact match against the known list.
  if (BASE_SYSTEM_LIBS.has(soname)) return true;

  // Dynamic loader variants: ld-linux-*.so.* / ld-*.so.*
  if (/^ld-(linux|musl)[-.]/iu.test(soname)) return true;

  return false;
}

function patchelfRpath(file) {
  // Set rpath to $ORIGIN so the lib finds its siblings in the same directory.
  const result = spawnSync("patchelf", ["--set-rpath", "$ORIGIN", file], {
    stdio: "pipe",
    encoding: "utf8",
  });
  if (result.status !== 0) {
    const detail = (result.stderr || "").trim();
    // patchelf fails harmlessly on non-ELF files; surface real errors.
    if (!/not an elf/iu.test(detail)) {
      fail(`patchelf --set-rpath failed for ${file}: ${detail}`);
    }
  }
}

function realpathSafe(target) {
  try {
    return realpathSync(target);
  } catch {
    return target;
  }
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--root":
        parsed.root = argv[index + 1];
        index += 1;
        break;
      case "--staging":
        parsed.staging = argv[index + 1];
        index += 1;
        break;
      case "--addon":
        parsed.addon = argv[index + 1];
        index += 1;
        break;
      default:
        fail(`Unknown option: ${arg}`);
    }
  }
  return parsed;
}

function fail(message) {
  console.error(`native-audio: ${message}`);
  process.exit(1);
}
