#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const addonDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(addonDirectory, "../../../../..");

const includeDirectory = findFirstExistingDirectory([
  process.env.AONSOKU_LIBMPV_INCLUDE_DIR,
  ...platformIncludeCandidates(),
]);
const libraryDirectory = findFirstExistingDirectory([
  process.env.AONSOKU_LIBMPV_LIB_DIR,
  ...platformLibraryCandidates(),
]);
const library = process.env.AONSOKU_LIBMPV_LIBRARY ?? defaultLibraryName();
const nodeGyp = findNodeGyp(repoRoot);

if (!nodeGyp) {
  fail(
    "Unable to find node-gyp. Run pnpm install first, or set up @electron/node-gyp.",
  );
}

if (!includeDirectory || !existsSync(path.join(includeDirectory, "mpv"))) {
  fail(
    [
      "Unable to find libmpv headers.",
      "Install mpv/libmpv development files, or set AONSOKU_LIBMPV_INCLUDE_DIR.",
      "Expected a directory containing mpv/client.h.",
    ].join(" "),
  );
}

if (!libraryDirectory || !hasLibMpvLibrary(libraryDirectory)) {
  fail(
    [
      "Unable to find the libmpv dynamic/import library.",
      "Install libmpv, or set AONSOKU_LIBMPV_LIB_DIR and AONSOKU_LIBMPV_LIBRARY.",
    ].join(" "),
  );
}

const result = spawnSync(process.execPath, [nodeGyp, "configure", "build"], {
  cwd: addonDirectory,
  env: {
    ...process.env,
    AONSOKU_LIBMPV_INCLUDE_DIR: includeDirectory,
    AONSOKU_LIBMPV_LIB_DIR: libraryDirectory,
    AONSOKU_LIBMPV_LIBRARY: library,
  },
  stdio: "inherit",
});

process.exit(result.status ?? 1);

function findNodeGyp(root) {
  // Resolve the real node-gyp JS entry point instead of the `node_modules/.bin`
  // shim. On Unix `.bin/node-gyp` is a symlink to `../node-gyp/bin/node-gyp.js`
  // so `node <shim>` happens to work, but on Windows pnpm writes a shell-shim
  // file (no extension) that must be executed by a shell, not parsed by node —
  // `node <shim>` fails with `SyntaxError: missing ) after argument list` on
  // the shim's `basedir=$(dirname ...)`. Always locate the actual `.js` file.
  const binShim = path.join(root, "node_modules", ".bin", "node-gyp");
  if (existsSync(binShim)) {
    try {
      if (lstatSync(binShim).isSymbolicLink()) {
        return realpathSync(binShim);
      }
    } catch {
      // Not a symlink (e.g. Windows shell shim) — fall through to the
      // direct package lookups below.
    }
  }

  // Direct hoisted package paths (pnpm hoists @electron/node-gyp here).
  const directCandidates = [
    path.join(
      root,
      "node_modules",
      "@electron",
      "node-gyp",
      "bin",
      "node-gyp.js",
    ),
    path.join(root, "node_modules", "node-gyp", "bin", "node-gyp.js"),
  ];
  for (const candidate of directCandidates) {
    if (existsSync(candidate)) return candidate;
  }

  const pnpmDirectory = path.join(root, "node_modules", ".pnpm");
  if (!existsSync(pnpmDirectory)) return null;

  for (const entry of readdirSync(pnpmDirectory)) {
    if (!entry.includes("node-gyp")) continue;

    const candidate = path.join(
      pnpmDirectory,
      entry,
      "node_modules",
      "@electron",
      "node-gyp",
      "bin",
      "node-gyp.js",
    );
    if (existsSync(candidate)) return candidate;

    const unscopedCandidate = path.join(
      pnpmDirectory,
      entry,
      "node_modules",
      "node-gyp",
      "bin",
      "node-gyp.js",
    );
    if (existsSync(unscopedCandidate)) return unscopedCandidate;
  }

  return null;
}

function findFirstExistingDirectory(candidates) {
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate;
  }

  return null;
}

function platformIncludeCandidates() {
  if (process.platform === "darwin") {
    return [
      "/opt/homebrew/include",
      "/usr/local/include",
      "/opt/local/include",
      "/usr/include",
    ];
  }

  if (process.platform === "win32") {
    return ["C:\\mpv\\include"];
  }

  return ["/usr/local/include", "/usr/include"];
}

function platformLibraryCandidates() {
  if (process.platform === "darwin") {
    return ["/opt/homebrew/lib", "/usr/local/lib", "/opt/local/lib"];
  }

  if (process.platform === "win32") {
    return ["C:\\mpv\\lib"];
  }

  return ["/usr/local/lib", "/usr/lib", "/usr/lib64"];
}

function hasLibMpvLibrary(directory) {
  const entries = readdirSync(directory);

  if (process.platform === "win32") {
    return entries.some((entry) => entry.toLowerCase() === "mpv.lib");
  }

  return entries.some((entry) => /^libmpv\.(so|dylib|[0-9])/u.test(entry));
}

function defaultLibraryName() {
  return process.platform === "win32" ? "mpv.lib" : "-lmpv";
}

function fail(message) {
  console.error(`native-audio: ${message}`);
  process.exit(1);
}
