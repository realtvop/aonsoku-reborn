import type { DesktopScrobbleBuffer } from "./scrobble-buffer";

const SCROBBLE_THRESHOLD_PERCENT = 0.5;
const SCROBBLE_THRESHOLD_MAX_SECONDS = 240;

export type DesktopScrobbleRequest = (options: {
  path: string;
  query: Record<string, string | number>;
}) => Promise<unknown>;

export interface DesktopScrobbleSubmitterOptions {
  buffer: DesktopScrobbleBuffer;
  request?: DesktopScrobbleRequest;
  now?: () => number;
}

export class DesktopScrobbleSubmitter {
  readonly #buffer: DesktopScrobbleBuffer;
  readonly #request: DesktopScrobbleRequest | null;
  readonly #now: () => number;
  #pendingSubmission: Promise<void> | null = null;

  constructor(options: DesktopScrobbleSubmitterOptions) {
    this.#buffer = options.buffer;
    this.#request = options.request ?? null;
    this.#now = options.now ?? (() => Date.now());
  }

  sendNowPlaying(songId: string): void {
    if (!this.#request) return;
    this.#request({
      path: "/scrobble.view",
      query: {
        id: songId,
        submission: "false",
        time: Math.trunc(this.#now()),
      },
    }).catch(() => {});
  }

  submitPending(): Promise<void> {
    if (!this.#request) return Promise.resolve();
    if (this.#pendingSubmission) return this.#pendingSubmission;

    this.#pendingSubmission = this.#drainPending().finally(() => {
      this.#pendingSubmission = null;
    });
    return this.#pendingSubmission;
  }

  async #drainPending(): Promise<void> {
    if (!this.#request) return;

    for (const entry of this.#buffer.getEntries()) {
      const threshold = Math.min(
        entry.songDurationSeconds * SCROBBLE_THRESHOLD_PERCENT,
        SCROBBLE_THRESHOLD_MAX_SECONDS,
      );
      if (threshold <= 0 || entry.playedDurationMs / 1000 < threshold) {
        this.#buffer.removeEntry(entry.entryId);
        continue;
      }

      try {
        await this.#request({
          path: "/scrobble.view",
          query: {
            id: entry.songId,
            submission: "true",
            time: Math.trunc(entry.timestamp),
          },
        });
      } catch {
        // Preserve this entry and the remaining order. A later playback or
        // ready lifecycle opportunity will retry without affecting playback.
        return;
      }
      this.#buffer.removeEntry(entry.entryId);
    }
  }
}
