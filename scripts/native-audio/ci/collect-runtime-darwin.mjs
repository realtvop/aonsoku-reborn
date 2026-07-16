#!/usr/bin/env node
/**
 * Collect the libmpv runtime dependency closure for macOS and stage it for
 * `prepare-libmpv-resources.mjs`.
 *
 * Homebrew ships libmpv with absolute install names (e.g.
 * /opt/homebrew/lib/libmpv.2.dylib) and its dependency dylibs are scattered
 * across the Homebrew prefix. A packaged macOS app cannot rely on the user's
 * Homebrew, so we copy libmpv and every Homebrew dylib it transitively depends
 * on into a staging directory, rewrite their install ids and cross-references
 * to `@loader_path/<name>`, and patch the built addon's reference to libmpv to
 * `@loader_path/libmpv.<ext>`.
 *
 * `@loader_path` resolves to the directory of the binary containing each load
 * command, so a flat directory of bundled dylibs (next to the addon) is
 * self-consistent.
 *
 * Usage:
 *   node scripts/native-audio/ci/collect-runtime-darwin.mjs \
 *     --root /opt/homebrew/lib/libmpv.2.dylib \
 *     --staging ./.native-audio-staging \
 *     --addon electron/main/native/audio/libmpv/build/Release/aonsoku_libmpv.node
 */
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  realpathSync,
  rmSync,
} from "node:fs";
import path from "node:path";

const args = parseArgs(process.argv.slice(2));
const rootLib = path.resolve(args.root ?? fail("--root is required"));
const staging = path.resolve(args.staging ?? "./.native-audio-staging");
const addon = args.addon ? path.resolve(args.addon) : null;

if (!existsSync(rootLib)) fail(`Root library not found: ${rootLib}`);
if (!/\.dylib$/u.test(rootLib)) {
  fail(`Root library must be a .dylib: ${rootLib}`);
}

rmSync(staging, { recursive: true, force: true });
mkdirSync(staging, { recursive: true });

const rootDir = path.dirname(rootLib);
const brewPrefix = detectBrewPrefix(rootDir);

console.log(`native-audio: root lib   ${rootLib}`);
console.log(`native-audio: staging   ${staging}`);
console.log(`native-audio: brewPrefix ${brewPrefix}`);

// 1. Walk the otool -L closure, keeping only Homebrew-provided dylibs.
const closure = collectClosure(rootLib, brewPrefix);
if (closure.length === 0) fail("No Homebrew dylibs found to bundle.");

// 2. Copy each dylib into staging and rewrite its install id.
for (const originalPath of closure) {
  const name = path.basename(originalPath);
  const dest = path.join(staging, name);
  if (originalPath !== dest) copyFileSync(originalPath, dest);
  run("install_name_tool", ["-id", `@loader_path/${name}`, dest]);
}

// 3. Rewrite each copied dylib's references to other bundled dylibs.
for (const originalPath of closure) {
  const name = path.basename(originalPath);
  const dest = path.join(staging, name);
  for (const depPath of otoolDependencies(dest)) {
    const depName = path.basename(depPath);
    if (
      closure.includes(depPath) ||
      closure.some((entry) => path.basename(entry) === depName)
    ) {
      run("install_name_tool", [
        "-change",
        depPath,
        `@loader_path/${depName}`,
        dest,
      ]);
    }
  }
}

// 4. Patch the addon's reference to libmpv so it loads from @loader_path.
if (addon && existsSync(addon)) {
  const rootName = path.basename(rootLib);
  const addonDeps = otoolDependencies(addon);
  for (const depPath of addonDeps) {
    if (path.basename(depPath) === rootName) {
      run("install_name_tool", [
        "-change",
        depPath,
        `@loader_path/${rootName}`,
        addon,
      ]);
    }
  }
  console.log(`native-audio: patched addon ${addon}`);
}

// 5. Re-sign every staged Mach-O ad-hoc. install_name_tool invalidates the
// existing (ad-hoc) signature, and on Apple Silicon a Mach-O with an invalid
// signature cannot be dlopen'ed. Ad-hoc signing keeps the libs loadable in
// the unsigned distribution build.
const signFiles = closure.map((originalPath) =>
  path.join(staging, path.basename(originalPath)),
);
if (addon && existsSync(addon)) signFiles.push(addon);
for (const file of signFiles) {
  run("codesign", ["--force", "--sign", "-", file]);
}
console.log(`native-audio: re-signed ${signFiles.length} Mach-O files`);

console.log(
  JSON.stringify(
    {
      ok: true,
      staging,
      bundled: closure.map((entry) => path.basename(entry)),
    },
    null,
    2,
  ),
);

function collectClosure(root, prefix) {
  const visited = new Set();
  const queue = [root];
  const result = [];

  while (queue.length > 0) {
    const current = queue.pop();
    const resolved = realpathSafe(current);
    if (visited.has(resolved)) continue;
    visited.add(resolved);

    if (!result.some((entry) => realpathSafe(entry) === resolved)) {
      result.push(current);
    }

    for (const dep of otoolDependencies(current)) {
      if (isSystemPath(dep) || dep.startsWith("@")) continue;
      if (!path.isAbsolute(dep)) continue;
      if (!isUnderPrefix(dep, prefix)) continue;
      if (!existsSync(dep)) continue;
      const depResolved = realpathSafe(dep);
      if (visited.has(depResolved)) continue;
      queue.push(dep);
    }
  }

  return result;
}

function otoolDependencies(library) {
  const result = spawnSync("otool", ["-L", library], { encoding: "utf8" });
  if (result.status !== 0) {
    fail(`otool -L failed for ${library}.`);
  }

  const lines = result.stdout.split(/\r?\n/u);
  // First line is the binary itself; dependencies follow.
  const deps = [];
  for (let index = 1; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (!line) continue;
    const match = /^(?<path>\S+) /u.exec(line);
    if (!match) continue;
    deps.push(match.groups.path);
  }
  return deps;
}

function detectBrewPrefix(libDir) {
  // libDir is typically /opt/homebrew/lib or /usr/local/lib.
  if (path.basename(libDir) === "lib") {
    return path.dirname(libDir);
  }
  return libDir;
}

function isUnderPrefix(target, prefix) {
  const relative = path.relative(prefix, target);
  return relative && !relative.startsWith("..") && !path.isAbsolute(relative);
}

function isSystemPath(target) {
  return (
    target.startsWith("/usr/lib/") ||
    target.startsWith("/System/") ||
    target.startsWith("/Library/") ||
    target === path.basename(target)
  );
}

function realpathSafe(target) {
  try {
    return realpathSync(target);
  } catch {
    return target;
  }
}

function run(command, params) {
  const result = spawnSync(command, params, { stdio: "inherit" });
  if (result.status !== 0) {
    fail(`Command failed: ${command} ${params.join(" ")}`);
  }
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--root":
        parsed.root = argv[index + 1];
        index += 1;
        break;
      case "--staging":
        parsed.staging = argv[index + 1];
        index += 1;
        break;
      case "--addon":
        parsed.addon = argv[index + 1];
        index += 1;
        break;
      default:
        fail(`Unknown option: ${arg}`);
    }
  }
  return parsed;
}

function fail(message) {
  console.error(`native-audio: ${message}`);
  process.exit(1);
}
