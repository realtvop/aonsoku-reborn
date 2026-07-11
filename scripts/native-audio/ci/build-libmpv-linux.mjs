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
 * Source acquisition is pinned by commit. The default --mpv-version is a
 * known release with a pinned expected commit SHA (see RELEASE_MPV_VERSIONS).
 * After clone/fetch the script runs `git rev-parse HEAD` and compares it to
 * the expected commit, failing the build on drift. To build a different
 * mpv revision, pass --mpv-version together with --expected-commit (a pinned
 * but non-release build) or --allow-unpinned (skip commit verification, e.g.
 * for local development on a moving branch).
 *
 * Usage:
 *   node scripts/native-audio/ci/build-libmpv-linux.mjs \
 *     --staging ./.native-audio-build \
 *     [--mpv-version v0.35.0] \
 *     [--expected-commit <40-hex-sha>] \
 *     [--allow-unpinned] \
 *     [--jobs N]
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { availableParallelism } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Known mpv releases and the exact commit SHA each release tag resolves to.
 * The default --mpv-version must be present here so the release build is
 * reproducible without extra flags. Keep this map in sync with the mpv tags
 * Aonsoku CI builds against; update both entries when bumping the default.
 */
export const RELEASE_MPV_VERSIONS = {
  // Annotated tag v0.35.0 -> commit "Release 0.35.0".
  "v0.35.0": "75d938912ddd50f5658d874c59e1b50e13b28bf1",
};

export const DEFAULT_MPV_VERSION = "v0.35.0";
export const MPV_GIT_URL = "https://github.com/mpv-player/mpv.git";

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  runCli();
}

function runCli() {
  const args = parseArgs(process.argv.slice(2));
  const staging = path.resolve(args.staging ?? "./.native-audio-build");
  const jobs = String(args.jobs ?? availableParallelism() ?? 4);

  let config;
  try {
    config = resolveMpvSourceConfig({
      mpvVersion: args.mpvVersion,
      expectedCommit: args.expectedCommit,
      allowUnpinned: args.allowUnpinned === true,
    });
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error));
  }

  const sourceDir = path.join(staging, "mpv-src");
  const buildDir = path.join(staging, "mpv-build");
  const installDir = path.join(staging, "install");

  console.log(`native-audio: building audio-only libmpv ${config.mpvVersion}`);
  if (config.verifyCommit) {
    console.log(`native-audio: expected commit ${config.expectedCommit}`);
  } else {
    console.log(
      "native-audio: commit verification disabled (non-release build)",
    );
  }
  console.log(`native-audio: staging  ${staging}`);
  console.log(`native-audio: jobs     ${jobs}`);

  if (config.warning) {
    console.warn(`native-audio: ${config.warning}`);
  }

  // 1. Acquire mpv source, pinned to the expected commit when verifying.
  ensureMpvSource({
    sourceDir,
    config,
    runGit: defaultRunGit,
  });

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
        mpvVersion: config.mpvVersion,
        expectedCommit: config.verifyCommit ? config.expectedCommit : null,
        verified: config.verifyCommit,
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
}

/**
 * Resolve the mpv source acquisition policy from CLI flags and the known
 * release map. Returns a descriptor used by the build orchestrator; never
 * calls process.exit so it can be unit-tested.
 *
 * Rules:
 *   - Known release (in RELEASE_MPV_VERSIONS):
 *       expected commit defaults to the pinned SHA; commit is verified.
 *       An explicit --expected-commit that differs from the pin is accepted
 *       but the build is flagged as non-release (override) with a warning.
 *   - Unknown --mpv-version:
 *       --expected-commit required for a pinned non-release build, OR
 *       --allow-unpinned to skip verification (clearly non-release).
 *       Without either, throw a guidance error so a drifting source cannot
 *       silently become a release artifact.
 */
export function resolveMpvSourceConfig({
  mpvVersion,
  expectedCommit,
  allowUnpinned,
  knownReleases = RELEASE_MPV_VERSIONS,
}) {
  const version = mpvVersion ?? DEFAULT_MPV_VERSION;
  const pinned = knownReleases[version];

  if (pinned) {
    if (
      expectedCommit &&
      normalizeSha(expectedCommit) !== normalizeSha(pinned)
    ) {
      return {
        mpvVersion: version,
        expectedCommit: normalizeSha(expectedCommit),
        verifyCommit: true,
        isRelease: false,
        warning: `Overriding pinned ${version} commit (${pinned}) with ${normalizeSha(
          expectedCommit,
        )}; build is non-release.`,
      };
    }
    return {
      mpvVersion: version,
      expectedCommit: pinned,
      verifyCommit: true,
      isRelease: true,
      warning: null,
    };
  }

  if (expectedCommit) {
    return {
      mpvVersion: version,
      expectedCommit: normalizeSha(expectedCommit),
      verifyCommit: true,
      isRelease: false,
      warning: `${version} is not a known Aonsoku release; building pinned non-release at ${normalizeSha(
        expectedCommit,
      )}.`,
    };
  }

  if (allowUnpinned) {
    return {
      mpvVersion: version,
      expectedCommit: null,
      verifyCommit: false,
      isRelease: false,
      warning: `${version} is not a known Aonsoku release and no --expected-commit was provided; skipping commit verification. This is NOT a reproducible release build.`,
    };
  }

  throw new Error(
    `--mpv-version ${version} is not a known Aonsoku release (${Object.keys(
      knownReleases,
    ).join(
      ", ",
    )}). Provide --expected-commit <sha> to pin a non-release build, or pass --allow-unpinned to explicitly skip commit verification.`,
  );
}

/**
 * Acquire the mpv source tree at the configured ref and, when verification is
 * enabled, assert the resolved HEAD matches the expected commit.
 */
function ensureMpvSource({ sourceDir, config, runGit }) {
  if (!existsSync(sourceDir)) {
    console.log(
      `native-audio: cloning mpv ${config.mpvVersion} from ${MPV_GIT_URL}`,
    );
    run("git", [
      "clone",
      "--depth",
      "1",
      "--branch",
      config.mpvVersion,
      MPV_GIT_URL,
      sourceDir,
    ]);
    if (config.verifyCommit) {
      verifySourceCommit({
        sourceDir,
        expectedCommit: config.expectedCommit,
        runGit,
      });
    }
    return;
  }

  console.log(`native-audio: source already present at ${sourceDir}`);

  if (!config.verifyCommit) {
    console.log(
      "native-audio: skipping commit verification for unpinned non-release build",
    );
    return;
  }

  // Reuse the cached tree only if it already resolves to the expected commit;
  // otherwise fetch the requested ref and re-check. This keeps the common
  // release case network-free while still catching drift.
  const head = runGit(["-C", sourceDir, "rev-parse", "HEAD"], {
    encoding: "utf8",
  });
  if (
    head.status === 0 &&
    normalizeSha(head.stdout) === normalizeSha(config.expectedCommit)
  ) {
    console.log(
      `native-audio: cached source matches pinned commit ${config.expectedCommit}`,
    );
    return;
  }

  console.log(
    `native-audio: cached source drifted; fetching ${config.mpvVersion}`,
  );
  run("git", [
    "-C",
    sourceDir,
    "fetch",
    "--depth",
    "1",
    "origin",
    config.mpvVersion,
  ]);
  run("git", ["-C", sourceDir, "checkout", "--force", "FETCH_HEAD"]);
  verifySourceCommit({
    sourceDir,
    expectedCommit: config.expectedCommit,
    runGit,
  });
}

/**
 * Verify that the HEAD commit of `sourceDir` matches `expectedCommit`.
 * Throws a descriptive Error on mismatch or git failure so callers can surface
 * it. Uses the injected `runGit` so it is unit-testable without a real repo.
 */
export function verifySourceCommit({ sourceDir, expectedCommit, runGit }) {
  if (!expectedCommit) {
    throw new Error(
      "verifySourceCommit called without an expected commit; this is a programming error.",
    );
  }
  const expected = normalizeSha(expectedCommit);
  const result = runGit(["-C", sourceDir, "rev-parse", "HEAD"], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || "").trim();
    throw new Error(
      `git rev-parse HEAD failed in ${sourceDir}${detail ? `: ${detail}` : "."}`,
    );
  }
  const actual = normalizeSha(result.stdout);
  if (actual !== expected) {
    throw new Error(
      `mpv source commit mismatch: expected ${expected}, got ${actual}. The mpv source has drifted from the pinned release. Either update RELEASE_MPV_VERSIONS for ${expectedCommit}, or pin a non-release build with --expected-commit.`,
    );
  }
  return { actualCommit: actual, expectedCommit: expected };
}

function normalizeSha(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase();
}

function defaultRunGit(args, options = {}) {
  return spawnSync("git", args, { encoding: "utf8", ...options });
}

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

export function parseArgs(argv) {
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
      case "--expected-commit":
        parsed.expectedCommit = argv[index + 1];
        index += 1;
        break;
      case "--allow-unpinned":
        parsed.allowUnpinned = true;
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
