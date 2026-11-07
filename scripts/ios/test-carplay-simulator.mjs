import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
const root = resolve(import.meta.dirname, "../..");
const result = spawnSync("bash", ["scripts/test-ios-native.sh"], {
  cwd: root,
  stdio: "inherit",
  env: process.env,
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
