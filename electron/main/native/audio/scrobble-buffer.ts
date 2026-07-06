import type {
  NativeScrobbleBufferResult,
  NativeScrobbleEntry,
} from "@aonsoku/audio-contract";

export interface DesktopScrobbleBufferOptions {
  now?: () => number;
}

export class DesktopScrobbleBuffer {
  readonly #now: () => number;
  #entries: NativeScrobbleEntry[] = [];
  #currentSongId: string | null = null;
  #accumulatedMs = 0;
  #segmentStartMs: number | null = null;
  #trackingStartTimestamp = 0;

  constructor(options: DesktopScrobbleBufferOptions = {}) {
    this.#now = options.now ?? (() => Date.now());
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

    return entry;
  }

  getScrobbleBuffer(): NativeScrobbleBufferResult {
    return {
      entries: this.#entries.map((entry) => ({ ...entry })),
    };
  }

  clear(): void {
    this.#entries = [];
  }

  #currentSegmentMs(): number {
    if (this.#segmentStartMs === null) return 0;

    return Math.max(0, Math.round(this.#now() - this.#segmentStartMs));
  }
}
