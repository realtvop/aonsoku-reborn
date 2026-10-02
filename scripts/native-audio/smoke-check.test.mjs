import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

const smokeScript = fileURLToPath(
  new URL(
    "../../electron/main/native/audio/libmpv/smoke-check.mjs",
    import.meta.url,
  ),
);
const directories = [];

afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

// Model a short native track reaching EOF while synchronous system-session
// work blocks JS. Exercise the real smoke script as a separate Node process.
function runSmoke({ delayMs = 0, failSeek = false } = {}) {
  const directory = mkdtempSync(path.join(tmpdir(), "aonsoku-smoke-test-"));
  directories.push(directory);
  const addon = path.join(directory, "binding.cjs");
  writeFileSync(
    addon,
    `module.exports = {
      runtimeInfo: () => ({ systemMediaSessionApiVersion: "2" }),
      createPlayer: () => {
        let callback, paused, keepOpen, loadedAt;
        return {
          setEventCallback(fn) { callback = fn; },
          initialize({ options }) {
            paused = options.pause === "yes";
            keepOpen = options["keep-open"] === "yes";
          },
          observeProperty() {},
          command([name]) {
            if (name === "loadfile") {
              loadedAt = Date.now();
              callback({ type: "file-loaded" });
            }
            if (name === "seek" && (${failSeek} ||
                (!paused && !keepOpen && Date.now() - loadedAt >= 2000))) {
              throw new Error("libmpv command failed: error running command");
            }
          },
          updateSystemMediaSession() {
            if (loadedAt && ${delayMs}) {
              Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ${delayMs});
            }
          },
          setProperty(name, value) {
            paused = value;
            callback({ type: "property-change", name, data: value });
            if (!paused) callback({ type: "property-change", name: "time-pos", data: 0.1 });
          },
          clearSystemMediaSession() {},
          destroy() {},
        };
      },
    };`,
  );
  return spawnSync(process.execPath, [smokeScript, "--addon", addon], {
    encoding: "utf8",
    timeout: 15_000,
  });
}

describe("native audio smoke check", () => {
  it("loads, seeks and verifies resumed playback", () => {
    const result = runSmoke();
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout).loadedFixture).toBe(true);
  });

  it("survives system-session work exceeding the fixture duration", () => {
    const result = runSmoke({ delayMs: 750 });
    expect(result.status, result.stderr).toBe(0);
  });

  it("reports the operation that failed", () => {
    const result = runSmoke({ failSeek: true });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("smoke check failed during seek");
  });
});
