#!/usr/bin/env node
import { spawnSync } from "node:child_process";
/**
 * Deep linkage verification for the Linux native-audio runtime bundle.
 *
 * `verify-libmpv-package.mjs` only checks that the files referenced by the
 * staged `manifest.json` exist on disk. On a Linux host targeting Linux it
 * also invokes this module so the packaged runtime is validated at the
 * dynamic-linker level, not just the filesystem level:
 *
 *   1. `ldd <file>` is run on the addon and every bundled `.so`. No
 *      dependency may be reported as `not found` — a missing dep would make
 *      the packaged app fail to load libmpv on a clean glibc >= 2.35 system.
 *   2. `readelf -d <file>` confirms the addon and every bundled `.so` carry a
 *      `$ORIGIN` rpath/RUNPATH, so the flat bundle directory resolves its own
 *      closure without touching system library paths.
 *   3. The addon's `libmpv.so` dependency must resolve to a path *inside* the
 *      bundle directory. If it resolves to a system path, the addon's
 *      `$ORIGIN` rpath is not taking effect and the packaged app would bind
 *      to the host's libmpv instead of the bundled audio-only build.
 *
 * The parsers are pure functions (exported) so they can be unit-tested without
 * spawning `ldd`/`readelf`. `verifyLinuxRuntimeLinkage` accepts an injectable
 * `runCommand` for the same reason.
 *
 * This is a Linux-only check. On any other host (or when targeting a non-Linux
 * platform) the orchestrator is a no-op that reports a single informational
 * warning, so `verify-libmpv-package.mjs` can call it unconditionally.
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ADDON_FILENAME = "aonsoku_libmpv.node";

/**
 * Parse `ldd <file>` stdout into a list of dependency entries.
 *
 * Recognised ldd line shapes:
 *   \tlibfoo.so.2 => /path/to/libfoo.so.2 (0xaddr)
 *   \tlibbar.so.1 => not found
 *   \tlinux-vdso.so.1 (0xaddr)               ← no path (vdso/loader), skipped
 *   \t/path/to/ld-linux-x86-64.so.2 (0xaddr) ← loader, no soname, skipped
 *
 * @param {string} stdout
 * @returns {Array<{ soname: string, path: string | null, notFound: boolean }>}
 */
export function parseLddOutput(stdout) {
  const entries = [];
  for (const line of stdout.split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    const arrowMatch = /^\s*(?<soname>\S+)\s+=>\s+(?<rest>.+)$/u.exec(trimmed);
    if (!arrowMatch) continue;

    const { soname, rest } = arrowMatch.groups;
    if (rest.trim() === "not found") {
      entries.push({ soname, path: null, notFound: true });
      continue;
    }

    const pathMatch = /^(?<path>\S+)\s+\(0x[0-9a-fA-F]+\)\s*$/u.exec(rest);
    if (pathMatch) {
      entries.push({ soname, path: pathMatch.groups.path, notFound: false });
      continue;
    }

    // Unrecognized `=>` shape; treat as unresolved so it surfaces.
    entries.push({ soname, path: null, notFound: true });
  }

  return entries;
}

/**
 * Parse `readelf -d <file>` stdout into the dynamic section's NEEDED entries
 * and RPATH/RUNPATH values.
 *
 * @param {string} stdout
 * @returns {{ needed: string[], rpath: string | null, runpath: string | null }}
 */
export function parseReadelfDynamic(stdout) {
  const needed = [];
  let rpath = null;
  let runpath = null;

  for (const line of stdout.split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    const neededMatch =
      /\(NEEDED\)\s+Shared library:\s+\[(?<name>[^\]]+)\]/u.exec(trimmed);
    if (neededMatch) {
      needed.push(neededMatch.groups.name);
      continue;
    }

    const rpathMatch =
      /\(RPATH\)\s+Library rpath:\s+\[(?<value>[^\]]+)\]/u.exec(trimmed);
    if (rpathMatch) {
      rpath = rpathMatch.groups.value;
      continue;
    }

    const runpathMatch =
      /\(RUNPATH\)\s+Library runpath:\s+\[(?<value>[^\]]+)\]/u.exec(trimmed);
    if (runpathMatch) {
      runpath = runpathMatch.groups.value;
    }
  }

  return { needed, rpath, runpath };
}

/**
 * @typedef {Object} VerifyOptions
 * @property {string} nativeAudioDirectory Absolute path to the platform-arch bundle dir.
 * @property {{ addon?: string, libraries?: string[], dependencies?: string[], requiredFiles?: string[] }} manifest
 * @property {string} [addonFilename] Defaults to `aonsoku_libmpv.node`.
 * @property {string} [hostPlatform] Defaults to `process.platform`. Used to gate the check.
 * @property {string} [targetPlatform] Defaults to `"linux"`.
 * @property {(file: string, tool: "ldd" | "readelf") => { status: number, stdout: string, stderr: string }} [runCommand]
 * @property {(absolutePath: string) => boolean} [existsFile]
 * @property {(relativePath: string) => string} [toRepoRelative] Defaults to path relative to nativeAudioDirectory's parent.
 */

/**
 * Verify the Linux runtime bundle's dynamic linkage.
 *
 * Returns `{ errors, warnings, checked }`. Never throws; all failures are
 * reported as `errors` entries so the caller can aggregate them.
 *
 * @param {VerifyOptions} options
 * @returns {{ errors: string[], warnings: string[], checked: string[] }}
 */
export function verifyLinuxRuntimeLinkage(options) {
  const {
    nativeAudioDirectory,
    manifest,
    addonFilename = ADDON_FILENAME,
    hostPlatform = process.platform,
    targetPlatform = "linux",
    runCommand = defaultRunCommand,
    existsFile = defaultExistsFile,
    toRepoRelative = defaultToRepoRelative,
  } = options ?? {};

  const errors = [];
  const warnings = [];
  const checked = [];

  if (targetPlatform !== "linux" || hostPlatform !== "linux") {
    warnings.push(
      [
        "Skipping Linux runtime linkage check:",
        `target=${targetPlatform}, host=${hostPlatform}.`,
        "ldd/readelf deep verification only runs on a Linux host targeting Linux.",
      ].join(" "),
    );
    return { errors, warnings, checked };
  }

  const addonPath = path.join(nativeAudioDirectory, addonFilename);
  const libraries = [
    ...(manifest.libraries ?? []),
    ...(manifest.dependencies ?? []),
  ].filter((name) => name !== addonFilename);

  if (!existsFile(addonPath)) {
    errors.push(`Linux linkage: missing addon ${toRepoRelative(addonPath)}`);
    return { errors, warnings, checked };
  }

  const targets = [
    { kind: "addon", relative: addonFilename, absolute: addonPath },
    ...libraries.map((name) => ({
      kind: "library",
      relative: name,
      absolute: path.join(nativeAudioDirectory, name),
    })),
  ];

  for (const target of targets) {
    if (!existsFile(target.absolute)) {
      errors.push(
        `Linux linkage: missing ${target.kind} ${toRepoRelative(target.absolute)}`,
      );
      continue;
    }

    const ldd = runCommand(target.absolute, "ldd");
    if (ldd.status !== 0) {
      errors.push(
        [
          `Linux linkage: ldd failed for ${toRepoRelative(target.absolute)}`,
          `(exit ${ldd.status}).`,
          ldd.stderr.trim() || ldd.stdout.trim(),
        ]
          .filter(Boolean)
          .join(" "),
      );
      continue;
    }

    const lddEntries = parseLddOutput(ldd.stdout);
    for (const entry of lddEntries) {
      if (entry.notFound) {
        errors.push(
          [
            `Linux linkage: ${toRepoRelative(target.absolute)} has an`,
            `unresolved dependency: ${entry.soname} => not found.`,
          ].join(" "),
        );
      }
    }

    const readelf = runCommand(target.absolute, "readelf");
    if (readelf.status !== 0) {
      errors.push(
        [
          `Linux linkage: readelf -d failed for`,
          `${toRepoRelative(target.absolute)} (exit ${readelf.status}).`,
          readelf.stderr.trim() || readelf.stdout.trim(),
        ]
          .filter(Boolean)
          .join(" "),
      );
      continue;
    }

    const dynamic = parseReadelfDynamic(readelf.stdout);
    if (!hasOriginRpath(dynamic)) {
      errors.push(
        [
          `Linux linkage: ${toRepoRelative(target.absolute)} is missing a`,
          "$ORIGIN rpath/RUNPATH. Bundled .so files must resolve siblings via",
          "$ORIGIN so the flat bundle directory is self-contained.",
        ].join(" "),
      );
    }

    checked.push(target.relative);
  }

  verifyAddonLibmpvBundleResolution({
    addonPath,
    nativeAudioDirectory,
    lddEntries: collectAddonLddEntries(addonPath, runCommand),
    toRepoRelative,
    errors,
  });

  return { errors, warnings, checked };
}

function collectAddonLddEntries(addonPath, runCommand) {
  const ldd = runCommand(addonPath, "ldd");
  if (ldd.status !== 0) return [];
  return parseLddOutput(ldd.stdout);
}

function verifyAddonLibmpvBundleResolution({
  addonPath,
  nativeAudioDirectory,
  lddEntries,
  toRepoRelative,
  errors,
}) {
  const libmpvEntries = lddEntries.filter((entry) =>
    /^libmpv\.so\b/u.test(entry.soname),
  );

  if (libmpvEntries.length === 0) {
    errors.push(
      [
        "Linux linkage: addon does not declare a libmpv.so dependency.",
        `Verify ${toRepoRelative(addonPath)} was linked against libmpv.`,
      ].join(" "),
    );
    return;
  }

  for (const entry of libmpvEntries) {
    if (entry.notFound || !entry.path) {
      errors.push(
        [
          "Linux linkage: addon's libmpv dependency is unresolved:",
          `${entry.soname} => not found.`,
        ].join(" "),
      );
      continue;
    }

    const resolved = path.resolve(entry.path);
    const bundle = path.resolve(nativeAudioDirectory);
    if (!isWithinDirectory(resolved, bundle)) {
      errors.push(
        [
          "Linux linkage: addon's libmpv dependency resolves outside the",
          `$ORIGIN bundle. ${entry.soname} => ${entry.path},`,
          `expected it under ${toRepoRelative(bundle)}.`,
          "The addon rpath is not taking effect or libmpv.so is missing",
          "from the bundle.",
        ].join(" "),
      );
    }
  }
}

function hasOriginRpath(dynamic) {
  const rpathValue = dynamic.runpath ?? dynamic.rpath;
  if (!rpathValue) return false;

  // rpath/RUNPATH may be a colon-separated list (e.g. "$ORIGIN:/usr/lib").
  return rpathValue
    .split(":")
    .map((entry) => entry.trim())
    .some((entry) => entry === "$ORIGIN");
}

function isWithinDirectory(target, directory) {
  const relative = path.relative(directory, target);
  return (
    relative === "" ||
    (!relative.startsWith("..") && !path.isAbsolute(relative))
  );
}

function defaultExistsFile(absolutePath) {
  return existsSync(absolutePath) && statSync(absolutePath).isFile();
}

function defaultRunCommand(file, tool) {
  if (tool === "ldd") {
    return spawnSync("ldd", [file], { encoding: "utf8" });
  }

  if (tool === "readelf") {
    return spawnSync("readelf", ["-d", file], { encoding: "utf8" });
  }

  return { status: 1, stdout: "", stderr: `Unknown tool: ${tool}` };
}

function defaultToRepoRelative(target) {
  return path.relative(path.resolve(process.cwd()), path.resolve(target));
}

// --- Standalone CLI -------------------------------------------------------

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  runCli();
}

function runCli() {
  const args = parseCliArgs(process.argv.slice(2));
  const platform =
    args.platform ?? process.env.AONSOKU_LIBMPV_PLATFORM ?? process.platform;
  const arch =
    args.arch ??
    process.env.AONSOKU_LIBMPV_ARCH ??
    process.env.ARCH ??
    process.arch;
  const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(scriptDirectory, "../..");
  const nativeAudioDirectory = path.resolve(
    repoRoot,
    args.resourcesRoot ?? "resources",
    "native-audio",
    `${platform}-${arch}`,
  );

  if (!existsSync(nativeAudioDirectory)) {
    console.error(
      `native-audio: missing Linux runtime bundle: ${nativeAudioDirectory}`,
    );
    process.exit(1);
  }

  const manifestPath = path.join(nativeAudioDirectory, "manifest.json");
  if (!existsSync(manifestPath)) {
    console.error(`native-audio: missing manifest: ${manifestPath}`);
    process.exit(1);
  }

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const result = verifyLinuxRuntimeLinkage({
    nativeAudioDirectory,
    manifest,
    hostPlatform: process.platform,
    targetPlatform: platform,
  });

  const payload = {
    ok: result.errors.length === 0,
    platformKey: `${platform}-${arch}`,
    nativeAudioDirectory,
    checked: result.checked,
    errors: result.errors,
    warnings: result.warnings,
  };

  if (result.errors.length > 0) {
    console.error(JSON.stringify(payload, null, 2));
    process.exit(1);
  }

  console.log(JSON.stringify(payload, null, 2));
}

function parseCliArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--platform":
        parsed.platform = argv[index + 1];
        index += 1;
        break;
      case "--arch":
        parsed.arch = argv[index + 1];
        index += 1;
        break;
      case "--resources-root":
        parsed.resourcesRoot = argv[index + 1];
        index += 1;
        break;
      default:
        console.error(`native-audio: Unknown option: ${arg}`);
        process.exit(1);
    }
  }
  return parsed;
}
