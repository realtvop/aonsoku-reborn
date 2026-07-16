#!/usr/bin/env node
/**
 * Run the packaged libmpv smoke check, but only when the host platform matches
 * `--only <platform>`. Used by the `build:linux` / `make` / `publish` npm
 * scripts so Linux local/release paths cover `native-audio:smoke:packaged`
 * (CI already runs it via `.github/actions/setup-native-audio`) without
 * changing macOS/Windows behavior — on those hosts this wrapper is a no-op
 * that exits 0.
 *
 * Usage:
 *   node scripts/native-audio/run-packaged-smoke.mjs --only linux
 */
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const args = parseArgs(process.argv.slice(2));
const only = args.only ?? null;
const hostPlatform = process.platform;
const normalizedOnly = normalizePlatform(only);

if (normalizedOnly !== null && hostPlatform !== normalizedOnly) {
  console.log(
    [
      `native-audio: packaged smoke skipped on ${hostPlatform}`,
      `(restricted to ${normalizedOnly} via --only).`,
    ].join(" "),
  );
  process.exit(0);
}

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const smokeScript = path.resolve(
  scriptDirectory,
  "../../electron/main/native/audio/libmpv/smoke-check.mjs",
);

const result = spawnSync(process.execPath, [smokeScript, "--packaged-like"], {
  stdio: "inherit",
});

if (result.error) {
  console.error("native-audio: failed to spawn packaged smoke check");
  console.error(result.error);
  process.exit(1);
}

process.exit(result.status ?? 1);

function normalizePlatform(value) {
  if (value === null || value === undefined) return null;
  if (value === "mac" || value === "darwin") return "darwin";
  if (value === "win" || value === "win32") return "win32";
  if (value === "linux") return "linux";
  return value;
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--only":
        parsed.only = argv[index + 1];
        index += 1;
        break;
      default:
        console.error(`native-audio: Unknown option: ${arg}`);
        process.exit(1);
    }
  }
  return parsed;
}
