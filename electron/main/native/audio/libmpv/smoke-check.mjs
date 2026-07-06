#!/usr/bin/env node
import { createRequire } from "node:module";
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

try {
  player.initialize({
    options: {
      "audio-display": "no",
      "force-window": "no",
      idle: "yes",
      terminal: "no",
      vid: "no",
    },
  });
  player.observeProperty("pause", "boolean");
  player.destroy();

  console.log(
    JSON.stringify(
      {
        ok: true,
        addonPath,
        runtimeInfo: binding.runtimeInfo?.() ?? null,
        observedEvents: events.length,
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

  console.error("native-audio: libmpv smoke check failed");
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
