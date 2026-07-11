#!/usr/bin/env node
/**
 * Build an audio-only libmpv from source on Linux for the Aonsoku native
 * audio backend.
 *
 * The distribution libmpv package (libmpv-dev / libmpv2) pulls in the entire
 * graphics stack (GL/EGL/Vulkan/X11/DRM/libplacebo), making it unsuitable for
 * runtime bundling — that is why Aonsoku's Linux packages historically relied
 * on the host providing libmpv2. This script builds libmpv with every video
 * output, GPU, display, and hardware-acceleration feature disabled, producing
 * a libmpv.so whose only dynamic dependencies are FFmpeg, libass, audio output
 * client libraries, and base-system libs (libc/libm/ld-linux). The resulting
 * .so closure is small enough to bundle, which makes the .deb/.rpm/AppImage
 * self-contained without dragging in a graphics stack. The glibc baseline of
 * the bundled binaries follows the build environment (Ubuntu 22.04 / glibc
 * 2.35 in CI).
 *
 * The built library and headers are installed to a staging prefix. After this
 * script runs, set:
 *   AONSOKU_LIBMPV_INCLUDE_DIR=<staging>/install/include
 *   AONSOKU_LIBMPV_LIB_DIR=<staging>/install/lib
 *   AONSOKU_LIBMPV_LIBRARY=-lmpv
 * before building the Aonsoku Node-API addon.
 *
 * Build dependencies (must be pre-installed via apt or equivalent):
 *   build-essential git meson ninja-build pkg-config
 *   libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev
 *   libswresample-dev libswscale-dev
 *   libass-dev libpulse-dev libasound2-dev
 *
 * Usage:
 *   node scripts/native-audio/ci/build-libmpv-linux.mjs \
 *     --staging ./.native-audio-build \
 *     [--mpv-version v0.35.0] \
 *     [--jobs N]
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { availableParallelism } from "node:os";
import path from "node:path";

const args = parseArgs(process.argv.slice(2));
const staging = path.resolve(args.staging ?? "./.native-audio-build");
const mpvVersion = args.mpvVersion ?? "v0.35.0";
const jobs = String(args.jobs ?? availableParallelism() ?? 4);

const sourceDir = path.join(staging, "mpv-src");
const buildDir = path.join(staging, "mpv-build");
const installDir = path.join(staging, "install");

console.log(`native-audio: building audio-only libmpv ${mpvVersion}`);
console.log(`native-audio: staging  ${staging}`);
console.log(`native-audio: jobs     ${jobs}`);

// 1. Clone mpv source (shallow, pinned to the release tag).
if (!existsSync(sourceDir)) {
  run("git", [
    "clone",
    "--depth",
    "1",
    "--branch",
    mpvVersion,
    "https://github.com/mpv-player/mpv.git",
    sourceDir,
  ]);
} else {
  console.log(`native-audio: source already present at ${sourceDir}`);
}

// 2. Meson setup with all video/GPU/display/hwaccel features disabled.
rmSync(buildDir, { recursive: true, force: true });
mkdirSync(buildDir, { recursive: true });

const mesonOptions = [
  "setup",
  buildDir,
  sourceDir,
  `--prefix=${installDir}`,
  "--libdir=lib",
  "--buildtype=release",
  // libmpv only — no CLI player.
  "-Dlibmpv=true",
  "-Dcplayer=false",
  // ---- Video output / GPU / display — all disabled ----
  "-Dgl=disabled",
  "-Dplain-gl=disabled",
  "-Dvulkan=disabled",
  "-Degl=disabled",
  "-Dgbm=disabled",
  "-Dwayland=disabled",
  "-Dx11=disabled",
  "-Dxv=disabled",
  "-Ddrm=disabled",
  "-Dvaapi=disabled",
  "-Dvdpau=disabled",
  "-Dcaca=disabled",
  "-Dsixel=disabled",
  "-Dsdl2-video=disabled",
  // ---- Video/OSD optional features ----
  "-Djpeg=disabled",
  "-Dlcms2=disabled",
  "-Dlibarchive=disabled",
  "-Dlibbluray=disabled",
  "-Ddvdnav=disabled",
  "-Dcdda=disabled",
  "-Dvapoursynth=disabled",
  "-Dzimg=disabled",
  // ---- Scripting ----
  "-Dlua=disabled",
  "-Djavascript=disabled",
  "-Duchardet=disabled",
  // ---- Audio filters with heavy deps ----
  "-Drubberband=disabled",
  // ---- Audio outputs ----
  // Enable ALSA + PulseAudio. PulseAudio client lib also works on PipeWire
  // systems via pipewire-pulse, covering virtually all modern desktop Linux.
  "-Dalsa=enabled",
  "-Dpulse=enabled",
  "-Djack=disabled",
  "-Dopenal=disabled",
  "-Doss-audio=disabled",
  "-Dsndio=disabled",
  "-Dpipewire=disabled",
  "-Dsdl2-audio=disabled",
];

run("meson", mesonOptions);

// 3. Compile.
run("ninja", ["-C", buildDir, "-j", jobs]);

// 4. Install to the staging prefix.
run("meson", ["install", "-C", buildDir]);

// 5. Verify the output and report paths.
const libDir = path.join(installDir, "lib");
const includeDir = path.join(installDir, "include");

if (!existsSync(path.join(includeDir, "mpv", "client.h"))) {
  fail(`mpv/client.h not found in ${includeDir}`);
}

const libmpvPath = findLibmpv(libDir);
if (!libmpvPath) {
  fail(`libmpv.so not found in ${libDir}`);
}

console.log(
  JSON.stringify(
    {
      ok: true,
      mpvVersion,
      staging,
      installDir,
      libDir,
      includeDir,
      libmpvPath,
      env: {
        AONSOKU_LIBMPV_INCLUDE_DIR: includeDir,
        AONSOKU_LIBMPV_LIB_DIR: libDir,
        AONSOKU_LIBMPV_LIBRARY: "-lmpv",
      },
    },
    null,
    2,
  ),
);

function findLibmpv(directory) {
  if (!existsSync(directory)) return null;
  const entries = readdirSync(directory);
  return (
    entries.find((entry) => /^libmpv\.so$/u.test(entry)) ??
    entries.find((entry) => /^libmpv\.so\.\d+$/u.test(entry)) ??
    entries.find((entry) => /^libmpv\.so\.\d+\.\d+\.\d+$/u.test(entry)) ??
    null
  );
}

function run(command, params) {
  console.log(`native-audio: $ ${command} ${params.join(" ")}`);
  const result = spawnSync(command, params, { stdio: "inherit" });
  if (result.status !== 0) {
    fail(
      `Command failed (exit ${result.status}): ${command} ${params.join(" ")}`,
    );
  }
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--staging":
        parsed.staging = argv[index + 1];
        index += 1;
        break;
      case "--mpv-version":
        parsed.mpvVersion = argv[index + 1];
        index += 1;
        break;
      case "--jobs":
        parsed.jobs = Number.parseInt(argv[index + 1], 10);
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
