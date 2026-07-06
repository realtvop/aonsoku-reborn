import { Buffer } from "node:buffer";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { promises as fs } from "node:fs";
import type { NativeAudioCachedAudioFile } from "@aonsoku/audio-contract";

interface ElectronAppModule {
  app?: {
    getPath(name: "userData"): string;
  };
}

interface DesktopAudioCacheMetadata {
  songId: string;
  fileName: string;
  contentType: string;
  lastModifiedAt: number;
}

export interface DesktopAudioFileStoreOptions {
  cacheDirectory?: string | (() => string | Promise<string>);
}

const requireElectron = createRequire(import.meta.url);

export class DesktopAudioFileStore {
  readonly #cacheDirectory: string | (() => string | Promise<string>);

  constructor(options: DesktopAudioFileStoreOptions = {}) {
    this.#cacheDirectory =
      options.cacheDirectory ?? getDefaultDesktopAudioCacheDirectory;
  }

  async storeAudioFile(options: {
    songId: string;
    dataBase64: string;
    contentType: string;
  }): Promise<NativeAudioCachedAudioFile> {
    validateSongId(options.songId);

    const data = decodeAudioBase64(options.dataBase64);
    const directory = await this.#resolveCacheDirectory({ create: true });
    await this.deleteAudioFile(options.songId);

    const contentType = options.contentType || "audio/mpeg";
    const cacheId = audioCacheId(options.songId);
    const fileName = `${cacheId}.${fileExtensionForContentType(contentType)}`;
    const filePath = path.join(directory, fileName);
    const tempPath = path.join(
      directory,
      `${fileName}.${process.pid}.${Date.now()}.tmp`,
    );

    await fs.writeFile(tempPath, data);
    await fs.rename(tempPath, filePath);

    const metadata: DesktopAudioCacheMetadata = {
      songId: options.songId,
      fileName,
      contentType,
      lastModifiedAt: Date.now(),
    };
    await this.#writeMetadata(options.songId, metadata, directory);

    return this.#toCachedAudioFile(options.songId, filePath, metadata);
  }

  async resolveAudioFile(
    songId: string,
  ): Promise<NativeAudioCachedAudioFile | null> {
    validateSongId(songId);

    const directory = await this.#resolveCacheDirectory({ create: false });
    if (!(await pathExists(directory))) return null;

    const metadata = await this.#readMetadata(songId, directory);
    const metadataFilePath = metadata?.fileName
      ? path.join(directory, metadata.fileName)
      : null;

    if (metadataFilePath && (await pathExists(metadataFilePath))) {
      return this.#toCachedAudioFile(songId, metadataFilePath, metadata);
    }

    const fallbackFilePath = await this.#findAudioFile(songId, directory);
    if (!fallbackFilePath) return null;

    return this.#toCachedAudioFile(songId, fallbackFilePath, metadata);
  }

  async getAudioFileSize(songId: string): Promise<number | null> {
    const file = await this.resolveAudioFile(songId);
    return file?.sizeBytes ?? null;
  }

  async deleteAudioFile(songId: string): Promise<boolean> {
    validateSongId(songId);

    const directory = await this.#resolveCacheDirectory({ create: false });
    if (!(await pathExists(directory))) return false;

    const cacheId = audioCacheId(songId);
    const entries = await fs.readdir(directory);
    let deleted = false;

    await Promise.all(
      entries
        .filter((entry) => entry.startsWith(`${cacheId}.`))
        .map(async (entry) => {
          await fs.rm(path.join(directory, entry), { force: true });
          deleted = true;
        }),
    );

    return deleted;
  }

  async clearAudioFiles(): Promise<number> {
    const directory = await this.#resolveCacheDirectory({ create: false });
    if (!(await pathExists(directory))) return 0;

    const entries = await fs.readdir(directory);
    let deletedAudioFileCount = 0;

    await Promise.all(
      entries.map(async (entry) => {
        if (!entry.endsWith(".json")) {
          deletedAudioFileCount++;
        }
        await fs.rm(path.join(directory, entry), { force: true });
      }),
    );

    return deletedAudioFileCount;
  }

  async #resolveCacheDirectory(options: { create: boolean }): Promise<string> {
    const directory =
      typeof this.#cacheDirectory === "function"
        ? await this.#cacheDirectory()
        : this.#cacheDirectory;

    if (options.create) {
      await fs.mkdir(directory, { recursive: true });
    }

    return directory;
  }

  async #writeMetadata(
    songId: string,
    metadata: DesktopAudioCacheMetadata,
    directory: string,
  ): Promise<void> {
    const metadataPath = path.join(directory, `${audioCacheId(songId)}.json`);
    const tempPath = `${metadataPath}.${process.pid}.${Date.now()}.tmp`;

    await fs.writeFile(tempPath, JSON.stringify(metadata), "utf8");
    await fs.rename(tempPath, metadataPath);
  }

  async #readMetadata(
    songId: string,
    directory: string,
  ): Promise<DesktopAudioCacheMetadata | null> {
    const metadataPath = path.join(directory, `${audioCacheId(songId)}.json`);

    try {
      const data = await fs.readFile(metadataPath, "utf8");
      const parsed = JSON.parse(data) as Partial<DesktopAudioCacheMetadata>;

      if (
        parsed.songId !== songId ||
        typeof parsed.fileName !== "string" ||
        typeof parsed.contentType !== "string" ||
        typeof parsed.lastModifiedAt !== "number"
      ) {
        return null;
      }

      return {
        songId: parsed.songId,
        fileName: parsed.fileName,
        contentType: parsed.contentType,
        lastModifiedAt: parsed.lastModifiedAt,
      };
    } catch {
      return null;
    }
  }

  async #findAudioFile(
    songId: string,
    directory: string,
  ): Promise<string | null> {
    const cacheId = audioCacheId(songId);
    const entries = await fs.readdir(directory);
    const fileName = entries.find(
      (entry) => entry.startsWith(`${cacheId}.`) && !entry.endsWith(".json"),
    );

    return fileName ? path.join(directory, fileName) : null;
  }

  async #toCachedAudioFile(
    songId: string,
    filePath: string,
    metadata: DesktopAudioCacheMetadata | null,
  ): Promise<NativeAudioCachedAudioFile> {
    const stat = await fs.stat(filePath);
    return {
      songId,
      uri: pathToFileURL(filePath).toString(),
      contentType: metadata?.contentType ?? "audio/mpeg",
      sizeBytes: stat.size,
      lastModifiedAt: metadata?.lastModifiedAt ?? stat.mtimeMs,
    };
  }
}

export function audioCacheId(songId: string): string {
  return Buffer.from(songId, "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/u, "");
}

export function audioCacheDirectoryFromUserDataPath(userDataPath: string) {
  return path.join(userDataPath, "AudioCache");
}

export function getDefaultDesktopAudioCacheDirectory(): string {
  const electron = requireElectron("electron") as ElectronAppModule;
  const userDataPath = electron.app?.getPath("userData");

  if (!userDataPath) {
    throw new Error(
      "Electron app userData path is unavailable for desktop audio cache.",
    );
  }

  return audioCacheDirectoryFromUserDataPath(userDataPath);
}

export function fileExtensionForContentType(contentType: string): string {
  const normalized = contentType.split(";", 1)[0]?.trim().toLowerCase() ?? "";

  switch (normalized) {
    case "audio/mpeg":
    case "audio/mp3":
      return "mp3";
    case "audio/flac":
    case "audio/x-flac":
      return "flac";
    case "audio/mp4":
    case "audio/m4a":
    case "audio/x-m4a":
      return "m4a";
    case "audio/aac":
      return "aac";
    case "audio/ogg":
    case "application/ogg":
      return "ogg";
    case "audio/opus":
      return "opus";
    case "audio/wav":
    case "audio/x-wav":
      return "wav";
    default:
      return "audio";
  }
}

function validateSongId(songId: string): void {
  if (!songId) {
    throw new Error("Missing songId for desktop audio cache.");
  }
}

function decodeAudioBase64(dataBase64: string): Buffer {
  const normalized = dataBase64.replace(/\s+/gu, "");
  if (!normalized || !/^[A-Za-z0-9+/]*={0,2}$/u.test(normalized)) {
    throw new Error("Desktop audio cache data is not valid base64.");
  }

  return Buffer.from(normalized, "base64");
}

async function pathExists(targetPath: string): Promise<boolean> {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}
