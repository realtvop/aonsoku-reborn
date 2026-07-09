import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import type {
  NativeScrobbleBufferResult,
  NativeScrobbleEntry,
} from "@aonsoku/audio-contract";

export interface DesktopScrobbleBufferOptions {
  now?: () => number;
  storageDirectory?: string | null;
}

interface ElectronAppModule {
  app?: {
    getPath(name: "userData"): string;
  };
}

const requireElectron = createRequire(import.meta.url);

export class DesktopScrobbleBuffer {
  readonly #now: () => number;
  readonly #storagePath: string | null;
  #entries: NativeScrobbleEntry[] = [];
  #currentSongId: string | null = null;
  #accumulatedMs = 0;
  #segmentStartMs: number | null = null;
  #trackingStartTimestamp = 0;

  constructor(options: DesktopScrobbleBufferOptions = {}) {
    this.#now = options.now ?? (() => Date.now());
    const storageDirectory =
      options.storageDirectory ?? getDefaultDesktopScrobbleStorageDirectory();
    this.#storagePath = storageDirectory
      ? path.join(storageDirectory, "scrobble-buffer.json")
      : null;
    this.#load();
  }

  get currentSongId(): string | null {
    return this.#currentSongId;
  }

  startTracking(
    songId: string,
    isPlaying: boolean,
  ): NativeScrobbleEntry | null {
    const flushed = this.stopTracking();

    this.#currentSongId = songId;
    this.#accumulatedMs = 0;
    this.#segmentStartMs = isPlaying ? this.#now() : null;
    this.#trackingStartTimestamp = this.#now();

    return flushed;
  }

  pauseTracking(): void {
    if (this.#segmentStartMs === null) return;

    this.#accumulatedMs += this.#currentSegmentMs();
    this.#segmentStartMs = null;
  }

  resumeTracking(): void {
    if (this.#currentSongId === null || this.#segmentStartMs !== null) return;

    this.#segmentStartMs = this.#now();
  }

  stopTracking(): NativeScrobbleEntry | null {
    const songId = this.#currentSongId;
    if (!songId) return null;

    const playedDurationMs = this.#accumulatedMs + this.#currentSegmentMs();
    const timestamp = this.#trackingStartTimestamp;

    this.#currentSongId = null;
    this.#accumulatedMs = 0;
    this.#segmentStartMs = null;
    this.#trackingStartTimestamp = 0;

    if (playedDurationMs <= 0) return null;

    const entry = {
      songId,
      playedDurationMs,
      timestamp,
    };
    this.#entries.push(entry);
    this.#persist();

    return entry;
  }

  getScrobbleBuffer(): NativeScrobbleBufferResult {
    return {
      entries: this.#entries.map((entry) => ({ ...entry })),
    };
  }

  clear(): void {
    this.#entries = [];
    this.#persist();
  }

  #currentSegmentMs(): number {
    if (this.#segmentStartMs === null) return 0;

    return Math.max(0, Math.round(this.#now() - this.#segmentStartMs));
  }

  #load(): void {
    if (!this.#storagePath || !existsSync(this.#storagePath)) return;

    try {
      const parsed = JSON.parse(readFileSync(this.#storagePath, "utf8"));
      if (!Array.isArray(parsed)) return;

      this.#entries = parsed.filter(isScrobbleEntry).map((entry) => ({
        songId: entry.songId,
        playedDurationMs: entry.playedDurationMs,
        timestamp: entry.timestamp,
      }));
    } catch {
      this.#entries = [];
    }
  }

  #persist(): void {
    if (!this.#storagePath) return;

    try {
      mkdirSync(path.dirname(this.#storagePath), { recursive: true });
      const temporaryPath = `${this.#storagePath}.${process.pid}.tmp`;
      writeFileSync(temporaryPath, JSON.stringify(this.#entries), "utf8");
      renameSync(temporaryPath, this.#storagePath);
    } catch {
      // Scrobbling must never disrupt playback when the local state cannot be
      // written (for example, during shutdown or a read-only userData path).
    }
  }
}

export function getDefaultDesktopScrobbleStorageDirectory(): string | null {
  try {
    const electron = requireElectron("electron") as ElectronAppModule;
    const userDataPath = electron.app?.getPath("userData");
    return userDataPath ? path.join(userDataPath, "NativeAudio") : null;
  } catch {
    return null;
  }
}

function isScrobbleEntry(value: unknown): value is NativeScrobbleEntry {
  if (typeof value !== "object" || value === null) return false;

  const entry = value as Partial<NativeScrobbleEntry>;
  return (
    typeof entry.songId === "string" &&
    typeof entry.playedDurationMs === "number" &&
    Number.isFinite(entry.playedDurationMs) &&
    entry.playedDurationMs > 0 &&
    typeof entry.timestamp === "number" &&
    Number.isFinite(entry.timestamp)
  );
}
