#!/usr/bin/env node
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { writeFile, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const addonDirectory = path.dirname(fileURLToPath(import.meta.url));
const addonPath =
  process.env.AONSOKU_LIBMPV_ADDON_PATH ??
  path.join(addonDirectory, "build", "Release", "aonsoku_libmpv.node");

let binding;
try {
  binding = require(addonPath);
} catch (error) {
  console.error(`native-audio: unable to load libmpv addon at ${addonPath}`);
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

const player = binding.createPlayer();
const events = [];
player.setEventCallback((event) => {
  events.push(event);
});
const wavPath = path.join(
  tmpdir(),
  `aonsoku-libmpv-smoke-${process.pid}.wav`,
);

try {
  await writeFile(wavPath, createSilentWav());

  player.initialize({
    options: {
      ao: "null",
      "audio-display": "no",
      "force-window": "no",
      idle: "yes",
      terminal: "no",
      vid: "no",
    },
  });
  player.observeProperty("pause", "boolean");
  player.command(["loadfile", wavPath, "replace"]);
  await waitForEvent(events, (event) => event.type === "file-loaded");
  player.command(["stop"]);
  player.destroy();
  await rm(wavPath, { force: true });

  console.log(
    JSON.stringify(
      {
        ok: true,
        addonPath,
        runtimeInfo: binding.runtimeInfo?.() ?? null,
        observedEvents: events.length,
        loadedFixture: true,
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

  console.error("native-audio: libmpv smoke check failed");
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

function createSilentWav() {
  const sampleRate = 8000;
  const seconds = 0.2;
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
