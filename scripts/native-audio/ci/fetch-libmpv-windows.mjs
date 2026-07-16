#!/usr/bin/env node
/**
 * Acquire libmpv development files for Windows on CI.
 *
 * Downloads a libmpv dev archive (and the matching full mpv archive for the
 * complete runtime DLL set) from the shinchiro/mpv-winbuild-cmake GitHub
 * releases, extracts them, stages the runtime DLLs, and generates an
 * MSVC-compatible `mpv.lib` import library from `libmpv-2.dll` when the archive
 * only ships the MinGW `libmpv.dll.a`.
 *
 * The script writes the following variables to `$GITHUB_ENV` so subsequent
 * workflow steps can build/prepare the native audio addon:
 *
 *   AONSOKU_LIBMPV_INCLUDE_DIR  -> directory containing mpv/client.h
 *   AONSOKU_LIBMPV_LIB_DIR      -> directory containing mpv.lib
 *   AONSOKU_LIBMPV_LIBRARY      -> "mpv.lib"
 *   AONSOKU_LIBMPV_RUNTIME_DIR  -> directory with all runtime DLLs to bundle
 *
 * Usage (run on a Windows runner, after `ilammy/msvc-dev-cmd` so dumpbin/lib
 * are on PATH):
 *
 *   node scripts/native-audio/ci/fetch-libmpv-windows.mjs --arch x64
 *   node scripts/native-audio/ci/fetch-libmpv-windows.mjs --arch arm64
 *
 * Override the upstream release tag with AONSOKU_MPV_WINBUILD_TAG (default
 * "latest"). Override the GitHub repository with
 * AONSOKU_MPV_WINBUILD_REPO (default "shinchiro/mpv-winbuild-cmake").
 */
import { spawnSync } from "node:child_process";
import {
  appendFileSync,
  copyFileSync,
  createWriteStream,
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import { writeFile } from "node:fs/promises";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";

const args = parseArgs(process.argv.slice(2));
const arch = args.arch ?? process.env.ARCH ?? "x64";
const shinchiroArch = arch === "arm64" ? "aarch64" : "x86_64";
const libMachine = arch === "arm64" ? "ARM64" : "X64";
const repo =
  process.env.AONSOKU_MPV_WINBUILD_REPO ?? "shinchiro/mpv-winbuild-cmake";
const tag = process.env.AONSOKU_MPV_WINBUILD_TAG ?? "latest";
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "../../..");
const workDir = path.join(repoRoot, ".native-audio-win");
const devExtract = path.join(workDir, "mpv-dev");
const fullExtract = path.join(workDir, "mpv");
const stageDir = path.join(workDir, "stage");

rmSync(workDir, { recursive: true, force: true });
mkdirSync(workDir, { recursive: true });
mkdirSync(stageDir, { recursive: true });
mkdirSync(devExtract, { recursive: true });
mkdirSync(fullExtract, { recursive: true });

const release = await fetchRelease(repo, tag);
const devAsset = findAsset(release, `mpv-dev-${shinchiroArch}-`);
const fullAsset = findAsset(release, `mpv-${shinchiroArch}-`, devAsset.name);
console.log(`native-audio: using dev asset  ${devAsset.name}`);
console.log(`native-audio: using full asset ${fullAsset.name}`);

const devArchive = path.join(workDir, devAsset.name);
const fullArchive = path.join(workDir, fullAsset.name);
await download(devAsset.browser_download_url, devArchive);
await download(fullAsset.browser_download_url, fullArchive);

await extract(devArchive, devExtract);
await extract(fullArchive, fullExtract);

const includeDir = path.join(devExtract, "include");
if (!existsSync(path.join(includeDir, "mpv", "client.h"))) {
  fail(`libmpv headers not found under ${includeDir}/mpv`);
}

// Stage every runtime DLL from both archives (dedup by name, full archive
// first so the dev import lib / headers are untouched).
collectDlls(fullExtract, stageDir);
collectDlls(devExtract, stageDir);

const libmpvDll = path.join(stageDir, "libmpv-2.dll");
if (!existsSync(libmpvDll)) {
  fail(`libmpv-2.dll not found after extraction (looked in ${stageDir}).`);
}

const libPath = await ensureImportLib(devExtract, stageDir, libmpvDll);

writeGitHubEnv({
  AONSOKU_LIBMPV_INCLUDE_DIR: includeDir,
  AONSOKU_LIBMPV_LIB_DIR: stageDir,
  AONSOKU_LIBMPV_LIBRARY: "mpv.lib",
  AONSOKU_LIBMPV_RUNTIME_DIR: stageDir,
});

console.log(
  JSON.stringify(
    {
      ok: true,
      arch,
      shinchiroArch,
      includeDir,
      libDir: stageDir,
      importLib: libPath,
      runtimeDlls: countDlls(stageDir),
    },
    null,
    2,
  ),
);

async function ensureImportLib(devDir, stage, dll) {
  const shippedLib = findFirstFile(devDir, "mpv.lib");
  if (shippedLib) {
    const target = path.join(stage, "mpv.lib");
    copyFileSync(shippedLib, target);
    console.log(`native-audio: using shipped mpv.lib from ${shippedLib}`);
    return target;
  }

  const defPath = path.join(stage, "mpv.def");
  const outPath = path.join(stage, "mpv.lib");
  const exports = dumpExports(dll);
  if (exports.length === 0) {
    fail(`dumpbin reported no exports for ${dll}.`);
  }

  const defContent = [
    "LIBRARY libmpv-2.dll",
    "EXPORTS",
    ...exports.map((name) => `  ${name}`),
    "",
  ].join("\n");
  await writeFile(defPath, defContent, "ascii");

  const result = spawnSync(
    "lib",
    [`/def:${defPath}`, `/machine:${libMachine}`, `/out:${outPath}`],
    { stdio: "inherit" },
  );

  if (result.status !== 0 || !existsSync(outPath)) {
    fail(
      [
        "Failed to generate mpv.lib from libmpv-2.dll.",
        "Ensure MSVC tools (lib.exe) are on PATH (e.g. via ilammy/msvc-dev-cmd).",
      ].join(" "),
    );
  }

  console.log(`native-audio: generated mpv.lib from ${dll}`);
  return outPath;
}

function dumpExports(dll) {
  const result = spawnSync("dumpbin", ["/exports", dll], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    fail(
      [
        "dumpbin /exports failed for libmpv-2.dll.",
        "Ensure MSVC tools (dumpbin.exe) are on PATH (e.g. via ilammy/msvc-dev-cmd).",
      ].join(" "),
    );
  }

  // dumpbin lists exports like:
  //     1    0 00001234 mpv_create
  const names = [];
  for (const line of result.stdout.split(/\r?\n/u)) {
    const match = /^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$/u.exec(
      line,
    );
    if (match && !match[1].startsWith("(forwarded")) {
      names.push(match[1]);
    }
  }

  return [...new Set(names)];
}

function collectDlls(sourceDir, destDir) {
  if (!existsSync(sourceDir)) return;
  for (const entry of readdirSync(sourceDir)) {
    if (!/\.dll$/iu.test(entry)) continue;
    const source = path.join(sourceDir, entry);
    if (!statSync(source).isFile()) continue;
    const dest = path.join(destDir, entry);
    if (!existsSync(dest)) {
      copyFileSync(source, dest);
    }
  }
}

function countDlls(dir) {
  return readdirSync(dir).filter((entry) => /\.dll$/iu.test(entry)).length;
}

function findFirstFile(dir, name) {
  if (!existsSync(dir)) return null;
  const direct = path.join(dir, name);
  if (existsSync(direct) && statSync(direct).isFile()) return direct;

  // Some archives nest files one level deep.
  for (const entry of readdirSync(dir)) {
    const candidate = path.join(dir, entry, name);
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }

  return null;
}

function findAsset(release, prefix, excludeName) {
  const candidates = (release.assets ?? []).filter(
    (asset) =>
      asset.name.startsWith(prefix) &&
      asset.name.endsWith(".7z") &&
      asset.name !== excludeName &&
      // Avoid the x86_64-v3 variant when targeting plain x86_64.
      !asset.name.includes("-v3-"),
  );
  if (candidates.length === 0) {
    fail(
      `No release asset matching "${prefix}*.7z" found in ${repo}@${release.tag_name}.`,
    );
  }
  // Prefer the most recent (assets are not guaranteed ordered, so sort by
  // updated_at descending).
  candidates.sort((a, b) => (a.updated_at < b.updated_at ? 1 : -1));
  return candidates[0];
}

async function fetchRelease(repository, releaseTag) {
  const url =
    releaseTag === "latest"
      ? `https://api.github.com/repos/${repository}/releases/latest`
      : `https://api.github.com/repos/${repository}/releases/tags/${releaseTag}`;
  const json = await fetchJson(url);
  if (!json || !json.assets) {
    fail(`GitHub API returned no assets for ${repository}@${releaseTag}.`);
  }
  return json;
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    https
      .get(
        url,
        {
          headers: {
            Accept: "application/vnd.github+json",
            "User-Agent": "aonsoku-native-audio-ci",
            ...(process.env.GITHUB_TOKEN
              ? { Authorization: `Bearer ${process.env.GITHUB_TOKEN}` }
              : {}),
          },
        },
        (response) => {
          if (response.statusCode === 301 || response.statusCode === 302) {
            fetchJson(response.headers.location).then(resolve, reject);
            response.resume();
            return;
          }
          if (response.statusCode !== 200) {
            reject(new Error(`GET ${url} -> ${response.statusCode}`));
            response.resume();
            return;
          }
          let body = "";
          response.setEncoding("utf8");
          response.on("data", (chunk) => {
            body += chunk;
          });
          response.on("end", () => {
            try {
              resolve(JSON.parse(body));
            } catch (error) {
              reject(error);
            }
          });
        },
      )
      .on("error", reject);
  });
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const getter = (current) => {
      https
        .get(
          current,
          {
            headers: { "User-Agent": "aonsoku-native-audio-ci" },
          },
          (response) => {
            if (response.statusCode === 301 || response.statusCode === 302) {
              response.resume();
              getter(response.headers.location);
              return;
            }
            if (response.statusCode !== 200) {
              reject(new Error(`GET ${current} -> ${response.statusCode}`));
              response.resume();
              return;
            }
            const stream = createWriteStream(dest);
            response.pipe(stream);
            stream.on("finish", resolve);
            stream.on("error", reject);
          },
        )
        .on("error", reject);
    };
    getter(url);
  });
}

async function extract(archive, dest) {
  const sevenZip = findSevenZip();
  const result = spawnSync(sevenZip, ["x", archive, `-o${dest}`, "-y", "-bd"], {
    stdio: "inherit",
  });
  if (result.status !== 0) {
    fail(`7z extraction failed for ${archive}.`);
  }
}

function findSevenZip() {
  const candidates = [
    "7z",
    "C:\\Program Files\\7-Zip\\7z.exe",
    "C:\\Program Files (x86)\\7-Zip\\7z.exe",
  ];
  for (const candidate of candidates) {
    const result = spawnSync(candidate, ["-h"], { stdio: "ignore" });
    if (result.status === 0) return candidate;
  }
  fail("7z not found. Install 7-Zip on the runner.");
}

function writeGitHubEnv(vars) {
  const envFile = process.env.GITHUB_ENV;
  if (!envFile) {
    console.warn("native-audio: GITHUB_ENV not set; exporting to stdout only.");
    for (const [key, value] of Object.entries(vars)) {
      console.log(`${key}=${value}`);
    }
    return;
  }

  const lines = Object.entries(vars)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  appendFileSync(envFile, `${lines}\n`);
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--arch":
        parsed.arch = argv[index + 1];
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
