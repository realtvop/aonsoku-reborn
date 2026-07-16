import { randomUUID } from "node:crypto";
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

export interface DesktopScrobbleEntry extends NativeScrobbleEntry {
  entryId: string;
  songDurationSeconds: number;
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
  #entries: DesktopScrobbleEntry[] = [];
  #currentSongId: string | null = null;
  #currentSongDurationSeconds = 0;
  #accumulatedMs = 0;
  #segmentStartMs: number | null = null;
  #trackingStartTimestamp = 0;

  constructor(options: DesktopScrobbleBufferOptions = {}) {
    this.#now = options.now ?? (() => Date.now());
    const storageDirectory =
      options.storageDirectory === undefined
        ? getDefaultDesktopScrobbleStorageDirectory()
        : options.storageDirectory;
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
    songDurationSeconds: number,
    isPlaying: boolean,
  ): DesktopScrobbleEntry | null {
    const flushed = this.stopTracking();

    this.#currentSongId = songId;
    this.#currentSongDurationSeconds = Math.max(0, songDurationSeconds);
    this.#accumulatedMs = 0;
    this.#segmentStartMs = isPlaying ? this.#now() : null;
    this.#trackingStartTimestamp = this.#now();

    return flushed;
  }

  updateCurrentDuration(songDurationSeconds: number): void {
    if (this.#currentSongId === null || songDurationSeconds <= 0) return;
    this.#currentSongDurationSeconds = songDurationSeconds;
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

  stopTracking(): DesktopScrobbleEntry | null {
    const songId = this.#currentSongId;
    if (!songId) return null;

    const playedDurationMs = this.#accumulatedMs + this.#currentSegmentMs();
    const timestamp = this.#trackingStartTimestamp;
    const songDurationSeconds = this.#currentSongDurationSeconds;

    this.#currentSongId = null;
    this.#currentSongDurationSeconds = 0;
    this.#accumulatedMs = 0;
    this.#segmentStartMs = null;
    this.#trackingStartTimestamp = 0;

    if (playedDurationMs <= 0) return null;

    const entry = {
      entryId: randomUUID(),
      songId,
      playedDurationMs,
      timestamp,
      songDurationSeconds,
    };
    this.#entries.push(entry);
    this.#persist();

    return entry;
  }

  getScrobbleBuffer(): NativeScrobbleBufferResult {
    return {
      entries: this.#entries.map(({ songId, playedDurationMs, timestamp }) => ({
        songId,
        playedDurationMs,
        timestamp,
      })),
    };
  }

  getEntries(): DesktopScrobbleEntry[] {
    return this.#entries.map((entry) => ({ ...entry }));
  }

  removeEntry(entryId: string): void {
    const index = this.#entries.findIndex((entry) => entry.entryId === entryId);
    if (index < 0) return;
    this.#entries.splice(index, 1);
    this.#persist();
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

      this.#entries = parsed.filter(isScrobbleEntry).map((entry, index) => ({
        entryId:
          typeof entry.entryId === "string" && entry.entryId.length > 0
            ? entry.entryId
            : `legacy-${entry.timestamp}-${index}-${entry.songId}`,
        songId: entry.songId,
        playedDurationMs: entry.playedDurationMs,
        timestamp: entry.timestamp,
        songDurationSeconds:
          typeof entry.songDurationSeconds === "number" &&
          Number.isFinite(entry.songDurationSeconds) &&
          entry.songDurationSeconds > 0
            ? entry.songDurationSeconds
            : Math.min(entry.playedDurationMs / 500, 480),
      }));
      this.#persist();
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

function isScrobbleEntry(
  value: unknown,
): value is NativeScrobbleEntry &
  Partial<Pick<DesktopScrobbleEntry, "entryId" | "songDurationSeconds">> {
  if (typeof value !== "object" || value === null) return false;

  const entry = value as Partial<DesktopScrobbleEntry>;
  return (
    typeof entry.songId === "string" &&
    typeof entry.playedDurationMs === "number" &&
    Number.isFinite(entry.playedDurationMs) &&
    entry.playedDurationMs > 0 &&
    typeof entry.timestamp === "number" &&
    Number.isFinite(entry.timestamp)
  );
}
