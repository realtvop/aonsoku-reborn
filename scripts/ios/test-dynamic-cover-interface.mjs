import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const build = mkdtempSync(join(tmpdir(), "aonsoku-cover-interface-"));
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(`${command} exited with ${result.status}`);
}
try {
  const executable = join(build, "interface-tests");
  run("xcrun", [
    "swiftc",
    "ios/AonsokuKit/Sources/AonsokuKit/Audio/DynamicCoverRegistry.swift",
    "scripts/ios/dynamic-cover-interface-tests.swift",
    "-o",
    executable,
  ]);
  run(executable, []);
} finally {
  rmSync(build, { recursive: true, force: true });
}
