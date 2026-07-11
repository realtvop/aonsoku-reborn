#!/usr/bin/env node
/**
 * Backport Visual Studio 2026 (internal version 18.x) detection to
 * `@electron/node-gyp`'s `find-visualstudio.js`.
 *
 * The Electron fork of node-gyp (`@electron/node-gyp`) was archived on
 * 2025-10-11 and pinned in this repo via a git tarball. Its `find-visualstudio`
 * only recognises VS 2017/2019/2022 (versionMajor 15/16/17), so on GitHub
 * Actions `windows-latest` / `windows-11-arm` runners — which now resolve to
 * the `win25-vs2026` image with Visual Studio 18 (2026) — node-gyp fails with
 *
 *   gyp ERR! find VS - unsupported version: 18
 *   gyp ERR! find VS - invalid versionYear: undefined
 *   gyp ERR! find VS could not find a version of Visual Studio 2017 or newer
 *
 * Upstream `nodejs/node-gyp` added VS 2026 support in commit 69e5fd2 (released
 * in v12.1.0). This script applies the same minimal change to the installed
 * `@electron/node-gyp` in-place: map versionMajor 18 → versionYear 2026,
 * toolset `v145`, and add `2026` to the "2019 or newer" search lists.
 *
 * The patch is idempotent: if the file already recognises version 18 it exits
 * cleanly. It is invoked from `build-addon.mjs` on Windows before spawning
 * node-gyp, so it covers both CI and local Windows development without
 * touching the pnpm lockfile or relying on `patchedDependencies` for a
 * git-tarball-resolved, archived package.
 */
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, "../../..");

const targetFile = resolveFindVisualStudio(repoRoot);
if (!targetFile || !existsSync(targetFile)) {
  // node-gyp isn't installed (or isn't resolvable yet) — nothing to patch.
  // The subsequent `node-gyp configure` will fail with a clearer error.
  console.log(
    "native-audio: patch-node-gyp-vs2026: find-visualstudio.js not found, skipping",
  );
  process.exit(0);
}

const source = readFileSync(targetFile, "utf8");

if (
  source.includes("ret.versionYear = 2026") ||
  source.includes("versionMajor === 18")
) {
  console.log(
    `native-audio: patch-node-gyp-vs2026: already patched (${targetFile})`,
  );
  process.exit(0);
}

let patched = source;

// 1. "2019 or newer" search lists: [2019, 2022] -> [2019, 2022, 2026]
//    There are exactly three call sites (specified-location, setup-module,
//    powershell). All use the literal `[2019, 2022])` argument form.
const searchListMatches = patched.match(/\[2019, 2022\]\)/gu)?.length ?? 0;
patched = patched.replaceAll("[2019, 2022])", "[2019, 2022, 2026])");
if (searchListMatches !== 3) {
  console.error(
    `native-audio: patch-node-gyp-vs2026: expected 3 "[2019, 2022])" call sites, found ${searchListMatches} — refusing to patch`,
  );
  process.exit(1);
}

// 2. getVersionInfo: map versionMajor 18 -> versionYear 2026 (after 17->2022).
const versionInfoAnchor = `    if (ret.versionMajor === 17) {
      ret.versionYear = 2022
      return ret
    }
    this.log.silly('- unsupported version:', ret.versionMajor)`;
const versionInfoReplacement = `    if (ret.versionMajor === 17) {
      ret.versionYear = 2022
      return ret
    }
    if (ret.versionMajor === 18) {
      ret.versionYear = 2026
      return ret
    }
    this.log.silly('- unsupported version:', ret.versionMajor)`;
if (!patched.includes(versionInfoAnchor)) {
  console.error(
    "native-audio: patch-node-gyp-vs2026: getVersionInfo anchor not found — node-gyp layout changed, refusing to patch",
  );
  process.exit(1);
}
patched = patched.replace(versionInfoAnchor, versionInfoReplacement);

// 3. getToolset: map versionYear 2026 -> toolset v145 (after 2022->v143).
const toolsetAnchor = `    } else if (versionYear === 2022) {
      return 'v143'
    }
    this.log.silly('- invalid versionYear:', versionYear)`;
const toolsetReplacement = `    } else if (versionYear === 2022) {
      return 'v143'
    } else if (versionYear === 2026) {
      return 'v145'
    }
    this.log.silly('- invalid versionYear:', versionYear)`;
if (!patched.includes(toolsetAnchor)) {
  console.error(
    "native-audio: patch-node-gyp-vs2026: getToolset anchor not found — node-gyp layout changed, refusing to patch",
  );
  process.exit(1);
}
patched = patched.replace(toolsetAnchor, toolsetReplacement);

writeFileSync(targetFile, patched);
console.log(
  `native-audio: patch-node-gyp-vs2026: patched ${targetFile} (added VS 2026 / version 18 / toolset v145)`,
);

/**
 * Resolve `@electron/node-gyp/lib/find-visualstudio.js` from the repo root,
 * falling back to a `node_modules/.pnpm` walk the way `build-addon.mjs` does.
 */
function resolveFindVisualStudio(root) {
  try {
    return createRequire(path.join(root, "package.json")).resolve(
      "@electron/node-gyp/lib/find-visualstudio.js",
    );
  } catch {
    // Not resolvable as a top-level import — try the hoisted path directly.
  }

  const direct = path.join(
    root,
    "node_modules",
    "@electron",
    "node-gyp",
    "lib",
    "find-visualstudio.js",
  );
  if (existsSync(direct)) return direct;

  const pnpmDirectory = path.join(root, "node_modules", ".pnpm");
  if (!existsSync(pnpmDirectory)) return null;

  for (const entry of readdirSafe(pnpmDirectory)) {
    if (!entry.includes("node-gyp")) continue;

    const scoped = path.join(
      pnpmDirectory,
      entry,
      "node_modules",
      "@electron",
      "node-gyp",
      "lib",
      "find-visualstudio.js",
    );
    if (existsSync(scoped)) return scoped;

    const plain = path.join(
      pnpmDirectory,
      entry,
      "node_modules",
      "node-gyp",
      "lib",
      "find-visualstudio.js",
    );
    if (existsSync(plain)) return plain;
  }

  return null;
}

function readdirSafe(directory) {
  try {
    return readdirSync(directory);
  } catch {
    return [];
  }
}
