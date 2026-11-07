import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  throw new Error("iOS artwork validation requires macOS and Xcode.");
}
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const architecture = process.arch === "x64" ? "x86_64" : process.arch;
const build = mkdtempSync(join(tmpdir(), "aonsoku-artwork-tests-"));
const output = resolve(process.argv[2] ?? "/tmp/aonsoku-artwork-qa");
const source = join(
  root,
  "ios/AonsokuKit/Sources/AonsokuKit/Audio",
);
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(`${command} exited with ${result.status}`);
}
try {
  run("xcrun", [
    "swiftc",
    "-O",
    "-D",
    "DEBUG",
    "-target",
    `${architecture}-apple-macosx13.0`,
    ...[
      "LockScreenArtworkRenderer",
      "LockScreenArtworkVideo",
      "LockScreenArtworkStore",
      "LockScreenArtworkMotion",
      "LockScreenArtworkDepthModel",
      "LockScreenArtworkSettings",
      "LockScreenArtworkModelCatalog",
      "LockScreenArtworkModelManager",
      "LockScreenArtworkMeasurement",
      "LockScreenArtworkDiagnostics",
    ].map((name) => join(source, `${name}.swift`)),
    join(root, "scripts/ios/lock-screen-artwork-tests.swift"),
    "-o",
    join(build, "artwork-tests"),
  ]);
  run(join(build, "artwork-tests"), [
    output,
    join(root, "cypress/fixtures/coverArt.jpeg"),
  ]);
} finally {
  rmSync(build, { recursive: true, force: true });
}
