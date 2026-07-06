#!/usr/bin/env node
import { existsSync, readdirSync, statSync } from "node:fs";
import { copyFile, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

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
const addonPath = path.resolve(
  repoRoot,
  options.addon ??
    process.env.AONSOKU_LIBMPV_ADDON_PATH ??
    path.join(
      "electron",
      "main",
      "native",
      "audio",
      "libmpv",
      "build",
      "Release",
      ADDON_FILENAME,
    ),
);
const outputDirectory = path.resolve(
  repoRoot,
  options.output ?? path.join("resources", "native-audio", platformKey),
);
const requireRuntimeLibs =
  options.requireRuntimeLibs ||
  process.env.AONSOKU_LIBMPV_REQUIRE_RUNTIME_LIBS === "1";

if (!existsSync(addonPath)) {
  fail(`Missing native addon: ${addonPath}`);
}

if (options.clean && existsSync(outputDirectory)) {
  await rm(outputDirectory, { recursive: true, force: true });
}

await mkdir(outputDirectory, { recursive: true });

const copiedFiles = [];
await copyRuntimeFile(addonPath, ADDON_FILENAME);

const runtimeFiles = findRuntimeFiles({
  platform,
  explicitFiles: [
    ...splitPathList(process.env.AONSOKU_LIBMPV_RUNTIME_LIBS),
    ...options.libraries,
  ],
  directories: [
    ...splitPathList(process.env.AONSOKU_LIBMPV_RUNTIME_DIRS),
    ...splitPathList(process.env.AONSOKU_LIBMPV_DEPENDENCY_DIR),
    ...options.runtimeDirectories,
  ],
});

if (runtimeFiles.length === 0 && requireRuntimeLibs) {
  fail(
    [
      "No libmpv runtime libraries were provided.",
      "Pass --lib, --runtime-dir, AONSOKU_LIBMPV_RUNTIME_LIBS,",
      "or AONSOKU_LIBMPV_RUNTIME_DIRS.",
    ].join(" "),
  );
}

for (const filePath of runtimeFiles) {
  await copyRuntimeFile(filePath, path.basename(filePath));
}

const libraryFiles = copiedFiles
  .filter((file) => file !== ADDON_FILENAME)
  .sort();
const notes =
  libraryFiles.length === 0
    ? [
        "No libmpv runtime libraries were copied. This layout is suitable only",
        "for source-build smoke checks or systems where libmpv is provided by",
        "the platform package manager.",
      ]
    : [];
const manifest = {
  schemaVersion: 1,
  platform,
  arch,
  platformKey,
  addon: ADDON_FILENAME,
  libraries: libraryFiles,
  dependencies: [],
  requiredFiles: [ADDON_FILENAME, ...libraryFiles],
  generatedAt: new Date().toISOString(),
  sources: {
    addon: path.relative(repoRoot, addonPath),
    libraries: runtimeFiles.map((file) => path.relative(repoRoot, file)),
  },
  notes,
};

await writeFile(
  path.join(outputDirectory, MANIFEST_FILENAME),
  `${JSON.stringify(manifest, null, 2)}\n`,
);

console.log(
  JSON.stringify(
    {
      ok: true,
      platformKey,
      outputDirectory,
      copiedFiles,
      manifest: path.join(outputDirectory, MANIFEST_FILENAME),
    },
    null,
    2,
  ),
);

async function copyRuntimeFile(sourcePath, targetName) {
  const destination = path.join(outputDirectory, targetName);
  await copyFile(sourcePath, destination);
  copiedFiles.push(targetName);
}

function findRuntimeFiles({ platform, explicitFiles, directories }) {
  const files = [];

  for (const filePath of explicitFiles) {
    const absolutePath = path.resolve(repoRoot, filePath);
    if (!existsSync(absolutePath)) {
      fail(`Missing libmpv runtime file: ${absolutePath}`);
    }
    files.push(absolutePath);
  }

  for (const directory of directories) {
    const absoluteDirectory = path.resolve(repoRoot, directory);
    if (!existsSync(absoluteDirectory)) {
      fail(`Missing libmpv runtime directory: ${absoluteDirectory}`);
    }

    for (const entry of readdirSync(absoluteDirectory)) {
      const filePath = path.join(absoluteDirectory, entry);
      if (!statSync(filePath).isFile()) continue;
      if (!isRuntimeLibraryName(entry, platform)) continue;

      files.push(filePath);
    }
  }

  return [...new Map(files.map((file) => [path.resolve(file), file])).values()];
}

function isRuntimeLibraryName(fileName, platform) {
  if (platform === "win32") return /\.dll$/iu.test(fileName);
  if (platform === "darwin") return /\.dylib$/u.test(fileName);

  return /\.so(?:\.\d+)*$/u.test(fileName);
}

function splitPathList(value) {
  if (!value) return [];

  return value.split(path.delimiter).filter(Boolean);
}

function parseArgs(argv) {
  const parsed = {
    libraries: [],
    runtimeDirectories: [],
    clean: false,
    requireRuntimeLibs: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--platform":
        parsed.platform = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--arch":
        parsed.arch = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--addon":
        parsed.addon = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--output":
        parsed.output = readArgValue(argv, index, arg);
        index += 1;
        break;
      case "--lib":
        parsed.libraries.push(readArgValue(argv, index, arg));
        index += 1;
        break;
      case "--runtime-dir":
        parsed.runtimeDirectories.push(readArgValue(argv, index, arg));
        index += 1;
        break;
      case "--clean":
        parsed.clean = true;
        break;
      case "--require-runtime-libs":
        parsed.requireRuntimeLibs = true;
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
