import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type {
  NativeAudioCachedAudioFile,
  NativeAudioEvents,
} from "@aonsoku/audio-contract";
import { audioCacheId, DesktopAudioFileStore } from "./cache";

export type DesktopAudioDownloadCompletionEventName =
  | "downloadCompleted"
  | "streamCacheCompleted";

export interface DesktopAudioDownloadRequest {
  songId: string;
  url: string;
  completionEventName: DesktopAudioDownloadCompletionEventName;
  reportProgress: boolean;
  reportFailure: boolean;
  skipIfCached?: boolean;
}

export interface DesktopAudioDownloadManagerOptions {
  audioFiles: DesktopAudioFileStore;
  onProgress: (event: NativeAudioEvents["downloadProgress"]) => void;
  onCompleted: (
    eventName: DesktopAudioDownloadCompletionEventName,
    event:
      | NativeAudioEvents["downloadCompleted"]
      | NativeAudioEvents["streamCacheCompleted"],
  ) => void;
  onFailed: (event: NativeAudioEvents["downloadFailed"]) => void;
}

interface ActiveDownload {
  controller: AbortController;
}

export class DesktopAudioDownloadManager {
  readonly #audioFiles: DesktopAudioFileStore;
  readonly #onProgress: DesktopAudioDownloadManagerOptions["onProgress"];
  readonly #onCompleted: DesktopAudioDownloadManagerOptions["onCompleted"];
  readonly #onFailed: DesktopAudioDownloadManagerOptions["onFailed"];
  readonly #activeDownloads = new Map<string, ActiveDownload>();

  constructor(options: DesktopAudioDownloadManagerOptions) {
    this.#audioFiles = options.audioFiles;
    this.#onProgress = options.onProgress;
    this.#onCompleted = options.onCompleted;
    this.#onFailed = options.onFailed;
  }

  download(request: DesktopAudioDownloadRequest): void {
    if (this.#activeDownloads.has(request.songId)) return;

    const activeDownload: ActiveDownload = {
      controller: new AbortController(),
    };
    this.#activeDownloads.set(request.songId, activeDownload);

    this.#runDownload(request, activeDownload)
      .finally(() => {
        if (this.#activeDownloads.get(request.songId) === activeDownload) {
          this.#activeDownloads.delete(request.songId);
        }
      })
      .catch(() => undefined);
  }

  cancel(songId: string): void {
    this.#activeDownloads.get(songId)?.controller.abort();
    this.#activeDownloads.delete(songId);
  }

  cancelAll(): void {
    for (const songId of this.#activeDownloads.keys()) {
      this.cancel(songId);
    }
  }

  async #runDownload(
    request: DesktopAudioDownloadRequest,
    activeDownload: ActiveDownload,
  ): Promise<void> {
    let tempDirectory: string | null = null;

    try {
      if (request.skipIfCached) {
        const existing = await this.#audioFiles.resolveAudioFile(
          request.songId,
        );
        if (existing) return;
      }

      const response = await fetch(request.url, {
        signal: activeDownload.controller.signal,
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const contentType = response.headers.get("content-type") ?? "audio/mpeg";
      const total = parseContentLength(response.headers.get("content-length"));
      tempDirectory = await fs.mkdtemp(
        path.join(tmpdir(), "aonsoku-audio-download-"),
      );
      const tempFilePath = path.join(
        tempDirectory,
        `${audioCacheId(request.songId)}.download`,
      );

      const loaded = await writeResponseToFile({
        response,
        filePath: tempFilePath,
        signal: activeDownload.controller.signal,
        onProgress: request.reportProgress
          ? (loadedBytes) => {
              this.#onProgress({
                songId: request.songId,
                loaded: loadedBytes,
                total,
              });
            }
          : undefined,
      });

      if (request.reportProgress) {
        this.#onProgress({
          songId: request.songId,
          loaded,
          total,
        });
      }

      const file = await this.#audioFiles.storeAudioFileFromPath({
        songId: request.songId,
        filePath: tempFilePath,
        contentType,
      });

      this.#onCompleted(
        request.completionEventName,
        cachedFileToDownloadEvent(file, contentType),
      );
    } catch (error) {
      if (activeDownload.controller.signal.aborted) {
        return;
      }

      if (request.reportFailure) {
        this.#onFailed({
          songId: request.songId,
          error: downloadErrorMessage(error),
        });
      }
    } finally {
      if (tempDirectory) {
        await fs.rm(tempDirectory, { force: true, recursive: true });
      }
    }
  }
}

function cachedFileToDownloadEvent(
  file: NativeAudioCachedAudioFile,
  contentType: string,
): NativeAudioEvents["downloadCompleted"] {
  return {
    songId: file.songId,
    uri: file.uri,
    contentType: file.contentType ?? contentType,
    sizeBytes: file.sizeBytes ?? 0,
  };
}

async function writeResponseToFile(options: {
  response: Response;
  filePath: string;
  signal: AbortSignal;
  onProgress?: (loadedBytes: number) => void;
}): Promise<number> {
  const file = await fs.open(options.filePath, "w");
  let loaded = 0;
  let lastProgressAt = 0;

  try {
    if (!options.response.body) {
      const data = Buffer.from(await options.response.arrayBuffer());
      await file.writeFile(data);
      loaded = data.byteLength;
      options.onProgress?.(loaded);
      return loaded;
    }

    const reader = options.response.body.getReader();

    while (true) {
      if (options.signal.aborted) {
        throw new Error("Download cancelled.");
      }

      const { done, value } = await reader.read();
      if (done) break;

      await file.write(value);
      loaded += value.byteLength;

      const now = Date.now();
      if (now - lastProgressAt >= 200) {
        options.onProgress?.(loaded);
        lastProgressAt = now;
      }
    }

    return loaded;
  } finally {
    await file.close();
  }
}

function parseContentLength(value: string | null): number {
  if (!value) return 0;

  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function downloadErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return "Desktop audio download failed.";
}
