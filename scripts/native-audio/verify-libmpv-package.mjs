#!/usr/bin/env node
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { verifyLinuxRuntimeLinkage } from "./linux-runtime-linkage.mjs";

const ADDON_FILENAME = "aonsoku_libmpv.node";
const MANIFEST_FILENAME = "manifest.json";
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, "../..");
const options = parseArgs(process.argv.slice(2));
const platform =
  options.platform ?? process.env.AONSOKU_LIBMPV_PLATFORM ?? process.platform;
const arch =
  options.arch ??
  process.env.AONSOKU_LIBMPV_ARCH ??
  process.env.ARCH ??
  process.arch;
const platformKey = `${platform}-${arch}`;
const resourcesRoot = path.resolve(
  repoRoot,
  options.resourcesRoot ?? "resources",
);
const nativeAudioDirectory = path.join(
  resourcesRoot,
  "native-audio",
  platformKey,
);
const requireNativeAudio =
  options.requireNativeAudio ||
  process.env.AONSOKU_REQUIRE_NATIVE_AUDIO_RESOURCES === "1";

const errors = [];
const warnings = [];

checkForgeConfig();
checkCommonResources();
checkNativeAudioResources();

if (errors.length > 0) {
  console.error(
    JSON.stringify(
      {
        ok: false,
        platformKey,
        errors,
        warnings,
      },
      null,
      2,
    ),
  );
  process.exit(1);
}

console.log(
  JSON.stringify(
    {
      ok: true,
      platformKey,
      resourcesRoot,
      nativeAudioDirectory,
      warnings,
    },
    null,
    2,
  ),
);

function checkForgeConfig() {
  const forgeConfigPath = path.join(repoRoot, "forge.config.ts");
  const contents = readRequiredTextFile(forgeConfigPath);

  assertIncludes(contents, "asar: true", "Forge asar packaging is enabled.");
  assertIncludes(
    contents,
    'extraResource: ["./resources"]',
    "Forge packages the resources directory as extraResource.",
  );
  assertIncludes(
    contents,
    'path === "/out"',
    "Forge ignore keeps electron-vite main/preload/renderer output.",
  );
  assertIncludes(
    contents,
    'path === "/resources"',
    "Forge ignore keeps packaged resources.",
  );
  assertIncludes(
    contents,
    'path.startsWith("/node_modules")',
    "Forge ignore excludes node_modules from app.asar.",
  );
}

function checkCommonResources() {
  for (const relativePath of [
    "build/icon.icns",
    "build/icon.ico",
    "build/icon.png",
    "resources/icons/icon.icns",
    "resources/icons/icon.ico",
    "resources/icons/icon.png",
    "resources/taskbar/light/play.png",
    "resources/taskbar/dark/play.png",
    "resources/assets/tray/mac/icon-16x16.png",
    "resources/assets/tray/other/icon-16x16.png",
  ]) {
    const filePath = path.join(repoRoot, relativePath);
    if (!existsSync(filePath)) {
      errors.push(`Missing packaged resource: ${relativePath}`);
    }
  }
}

function checkNativeAudioResources() {
  if (!existsSync(nativeAudioDirectory)) {
    const message = [
      `Missing native audio resources for ${platformKey}:`,
      path.relative(repoRoot, nativeAudioDirectory),
    ].join(" ");

    if (requireNativeAudio) {
      errors.push(message);
    } else {
      warnings.push(`${message}. Run pnpm native-audio:prepare.`);
    }
    return;
  }

  const addonPath = path.join(nativeAudioDirectory, ADDON_FILENAME);
  if (!isFile(addonPath)) {
    errors.push(`Missing libmpv addon: ${path.relative(repoRoot, addonPath)}`);
  }

  const manifestPath = path.join(nativeAudioDirectory, MANIFEST_FILENAME);
  if (!isFile(manifestPath)) {
    errors.push(
      `Missing libmpv manifest: ${path.relative(repoRoot, manifestPath)}`,
    );
    return;
  }

  const manifest = JSON.parse(readRequiredTextFile(manifestPath));
  const requiredFiles = manifest.requiredFiles ?? [
    manifest.addon ?? ADDON_FILENAME,
    ...(manifest.libraries ?? []),
    ...(manifest.dependencies ?? []),
  ];

  for (const fileName of requiredFiles) {
    const filePath = path.join(nativeAudioDirectory, fileName);
    if (!isFile(filePath)) {
      errors.push(
        [
          "Native audio manifest references a missing file:",
          path.relative(repoRoot, filePath),
        ].join(" "),
      );
    }
  }

  const runtimeLibraries = [
    ...(manifest.libraries ?? []),
    ...(manifest.dependencies ?? []),
  ];
  if (runtimeLibraries.length === 0) {
    const message = [
      `Native audio resources for ${platformKey} contain no libmpv`,
      "runtime libraries.",
    ].join(" ");

    if (requireNativeAudio) {
      errors.push(message);
    } else {
      warnings.push(message);
    }
  }

  // On a Linux host targeting Linux, additionally validate the bundled .so
  // closure at the dynamic-linker level (ldd/readelf): no `not found` deps,
  // every bundled .so carries $ORIGIN rpath, and the addon's libmpv resolves
  // from the $ORIGIN bundle. macOS/Windows and cross-builds skip this.
  const linkage = verifyLinuxRuntimeLinkage({
    nativeAudioDirectory,
    manifest,
    addonFilename: manifest.addon ?? ADDON_FILENAME,
    hostPlatform: process.platform,
    targetPlatform: platform,
  });
  for (const error of linkage.errors) {
    errors.push(error);
  }
  for (const warning of linkage.warnings) {
    warnings.push(warning);
  }
}

function readRequiredTextFile(filePath) {
  if (!existsSync(filePath)) {
    errors.push(`Missing file: ${path.relative(repoRoot, filePath)}`);
    return "";
  }

  return readFileSync(filePath, "utf8");
}

function assertIncludes(contents, needle, message) {
  if (contents.includes(needle)) return;

  errors.push(message);
}

function isFile(filePath) {
  return existsSync(filePath) && statSync(filePath).isFile();
}

function parseArgs(argv) {
  const parsed = {
    requireNativeAudio: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--":
        break;
      case "--platform":
        parsed.platform = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--arch":
        parsed.arch = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--resources-root":
        parsed.resourcesRoot = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--require-native-audio":
        parsed.requireNativeAudio = true;
        break;
      default:
        fail(`Unknown option: ${arg}`);
    }
  }

  return parsed;
}

function readArgValue(argv, index, name) {
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) {
    fail(`${name} expects a value.`);
  }

  return value;
}

function fail(message) {
  console.error(`native-audio: ${message}`);
  process.exit(1);
}
