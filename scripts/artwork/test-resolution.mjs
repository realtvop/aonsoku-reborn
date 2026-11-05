import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const output = mkdtempSync(join(tmpdir(), "aonsoku-resolution-"));
try {
  const paths = [
    "ios/AonsokuKit/Sources/AonsokuKit/Audio/LockScreenArtworkRenderer.swift",
    "ios/AonsokuKit/Sources/AonsokuKit/Audio/LockScreenArtworkSettings.swift",
    "scripts/artwork/resolution-tests.swift",
  ];
  const binary = join(output, "tests");
  for (const [cmd, args] of [
    ["xcrun", ["swiftc", "-O", ...paths, "-o", binary]],
    [binary, []],
  ]) {
    const result = spawnSync(cmd, args, { cwd: root, stdio: "inherit" });
    if (result.error) throw result.error;
    if (result.status !== 0)
      throw new Error(`${cmd} failed (${result.status})`);
  }
} finally {
  rmSync(output, { recursive: true, force: true });
}
