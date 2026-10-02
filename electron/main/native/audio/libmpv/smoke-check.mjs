#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const addonDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(addonDirectory, "../../../../..");
const args = parseArgs(process.argv.slice(2));
const addonPath =
  args.addon ??
  process.env.AONSOKU_LIBMPV_ADDON_PATH ??
  (args.packagedLike
    ? packagedLikeAddonPath()
    : path.join(addonDirectory, "build", "Release", "aonsoku_libmpv.node"));

validateRuntimeManifest(path.dirname(addonPath));
configureRuntimeSearchPath(path.dirname(addonPath));

let binding;
try {
  binding = require(addonPath);
} catch (error) {
  console.error(`native-audio: unable to load libmpv addon at ${addonPath}`);
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

const player = binding.createPlayer();
const runtimeInfo = binding.runtimeInfo?.() ?? {};
if (runtimeInfo.systemMediaSessionApiVersion !== "2") {
  throw new Error(
    "native-audio: addon does not provide system media session API version 2",
  );
}
for (const method of ["updateSystemMediaSession", "clearSystemMediaSession"]) {
  if (typeof player[method] !== "function") {
    throw new Error(`native-audio: addon is missing required method ${method}`);
  }
}
const events = [];
player.setEventCallback((event) => {
  events.push(event);
});
const wavPath = path.join(tmpdir(), `aonsoku-libmpv-smoke-${process.pid}.wav`);
let stage = "initialize";

try {
  await writeFile(wavPath, createSilentWav());

  player.initialize({
    options: {
      ao: "null",
      "audio-display": "no",
      "force-window": "no",
      idle: "yes",
      "keep-open": "yes",
      pause: "yes",
      terminal: "no",
      vid: "no",
    },
  });
  player.observeProperty("pause", "boolean");
  player.observeProperty("time-pos", "number");
  stage = "load";
  player.command(["loadfile", wavPath, "replace"]);
  await waitForEvent(events, (event) => event.type === "file-loaded");
  const metadata = {
    title: "Aonsoku native audio smoke test",
  };
  stage = "system-media-session";
  player.updateSystemMediaSession(metadata, {
    state: "paused",
    position: 0,
    duration: 2,
  });
  const availabilityPlayer = binding.createPlayer();
  availabilityPlayer.setEventCallback(() => {});
  availabilityPlayer.initialize({
    options: {
      ao: "null",
      "audio-display": "no",
      "force-window": "no",
      idle: "yes",
      terminal: "no",
      vid: "no",
    },
    registerSystemMediaSession: false,
  });
  availabilityPlayer.destroy();
  player.updateSystemMediaSession(metadata, {
    state: "paused",
    position: 0.1,
    duration: 2,
  });
  player.updateSystemMediaSession(metadata, {
    state: "paused",
    position: 0.05,
    duration: 2,
  });
  player.setProperty("pause", true);
  stage = "pause";
  await waitForEvent(
    events,
    (event) =>
      event.type === "property-change" &&
      event.name === "pause" &&
      event.data === true,
  );
  // Keep the short fixture paused during system-session/probe work: a slow
  // runner can otherwise reach EOF before the seek command is exercised.
  stage = "seek";
  player.command(["seek", "0.05", "absolute", "exact"]);
  stage = "resume";
  player.setProperty("pause", false);
  await waitForEvent(
    events,
    (event) =>
      event.type === "property-change" &&
      event.name === "time-pos" &&
      typeof event.data === "number" &&
      event.data > 0.05,
  );
  stage = "stop";
  player.command(["stop"]);
  stage = "destroy";
  player.clearSystemMediaSession();
  player.destroy();
  await rm(wavPath, { force: true });

  console.log(
    JSON.stringify(
      {
        ok: true,
        addonPath,
        mode: args.packagedLike ? "packaged-like" : "source-build",
        runtimeInfo,
        observedEvents: events.length,
        loadedFixture: true,
        exercised: [
          "load",
          "system-media-session",
          "availability-player-isolation",
          "pause",
          "resume",
          "seek",
          "stop",
          "destroy",
        ],
      },
      null,
      2,
    ),
  );
} catch (error) {
  try {
    player.destroy();
  } catch {
    // Ignore cleanup failures so the original smoke-check error is visible.
  }
  await rm(wavPath, { force: true });

  console.error(`native-audio: libmpv smoke check failed during ${stage}`);
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

function waitForEvent(events, predicate, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();

    const check = () => {
      const match = events.find(predicate);
      if (match) {
        resolve(match);
        return;
      }

      if (Date.now() - startedAt >= timeoutMs) {
        reject(new Error("Timed out waiting for libmpv fixture playback."));
        return;
      }

      setTimeout(check, 25);
    };

    check();
  });
}

function packagedLikeAddonPath() {
  return path.join(
    repoRoot,
    "resources",
    "native-audio",
    `${process.platform}-${process.arch}`,
    "aonsoku_libmpv.node",
  );
}

function validateRuntimeManifest(runtimeDirectory) {
  const manifestPath = path.join(runtimeDirectory, "manifest.json");
  if (!existsSync(manifestPath)) return;

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const requiredFiles = manifest.requiredFiles ?? [
    manifest.addon ?? "aonsoku_libmpv.node",
    ...(manifest.libraries ?? []),
    ...(manifest.dependencies ?? []),
  ];
  const missingFiles = requiredFiles.filter(
    (fileName) => !existsSync(path.join(runtimeDirectory, fileName)),
  );

  if (missingFiles.length > 0) {
    throw new Error(
      [
        "Packaged-like libmpv runtime is incomplete.",
        `Manifest: ${manifestPath}.`,
        `Missing: ${missingFiles.join(", ")}.`,
      ].join(" "),
    );
  }
}

function configureRuntimeSearchPath(runtimeDirectory) {
  if (process.platform !== "win32") return;

  process.env.PATH = [runtimeDirectory, process.env.PATH ?? ""]
    .filter(Boolean)
    .join(path.delimiter);
}

function parseArgs(argv) {
  const parsed = {
    packagedLike: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--addon":
        parsed.addon = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--packaged-like":
        parsed.packagedLike = true;
        break;
      default:
        console.error(`native-audio: Unknown option: ${arg}`);
        process.exit(1);
    }
  }

  return parsed;
}

function readArgValue(argv, index, name) {
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) {
    console.error(`native-audio: ${name} expects a value.`);
    process.exit(1);
  }

  return value;
}

function createSilentWav() {
  const sampleRate = 8000;
  const seconds = 2;
  const samples = Math.floor(sampleRate * seconds);
  const dataSize = samples * 2;
  const buffer = Buffer.alloc(44 + dataSize);

  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(36 + dataSize, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(dataSize, 40);

  return buffer;
}
