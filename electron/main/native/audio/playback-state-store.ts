import { promises as fs, readFileSync } from "node:fs";
import path from "node:path";
import type { NativeFullState } from "@aonsoku/audio-contract";
import { getDefaultDesktopScrobbleStorageDirectory } from "./scrobble-buffer";

export interface DesktopPlaybackStateStorage {
  load(): NativeFullState | null;
  save(state: NativeFullState): Promise<void>;
  clear(): Promise<void>;
}

export class DesktopPlaybackStateStore implements DesktopPlaybackStateStorage {
  readonly #filePath: string | null;
  #operationTail: Promise<void> = Promise.resolve();
  #temporarySequence = 0;

  constructor(storageDirectory = getDefaultDesktopScrobbleStorageDirectory()) {
    this.#filePath = storageDirectory
      ? path.join(storageDirectory, "playback-state.json")
      : null;
  }

  load(): NativeFullState | null {
    if (!this.#filePath) return null;
    try {
      const value = JSON.parse(readFileSync(this.#filePath, "utf8"));
      return isNativeFullState(value) ? value : null;
    } catch {
      return null;
    }
  }

  save(state: NativeFullState): Promise<void> {
    if (!this.#filePath) return Promise.resolve();
    let serialized: string;
    try {
      serialized = JSON.stringify(state);
    } catch {
      return Promise.resolve();
    }
    return this.#enqueue(async () => {
      const temporaryPath = `${this.#filePath}.${process.pid}.${++this.#temporarySequence}.tmp`;
      try {
        await fs.mkdir(path.dirname(this.#filePath as string), {
          recursive: true,
        });
        await fs.writeFile(temporaryPath, serialized, "utf8");
        await fs.rename(temporaryPath, this.#filePath as string);
      } finally {
        await fs.rm(temporaryPath, { force: true }).catch(() => {});
      }
    });
  }

  clear(): Promise<void> {
    if (!this.#filePath) return Promise.resolve();
    return this.#enqueue(() =>
      fs.rm(this.#filePath as string, { force: true }),
    );
  }

  #enqueue(operation: () => Promise<void>): Promise<void> {
    const result = this.#operationTail.then(operation, operation);
    this.#operationTail = result.catch(() => {
      // Persistence is best effort and must never interrupt playback.
    });
    return this.#operationTail;
  }
}

function isNativeFullState(value: unknown): value is NativeFullState {
  if (typeof value !== "object" || value === null) return false;
  const state = value as Partial<NativeFullState>;
  return (
    typeof state.contextQueue === "object" &&
    state.contextQueue !== null &&
    Array.isArray(state.contextQueue.songs) &&
    typeof state.contextQueue.currentIndex === "number" &&
    Array.isArray(state.userQueue) &&
    Array.isArray(state.originalContextSongs) &&
    Array.isArray(state.originalUserSongs) &&
    Array.isArray(state.shuffleHistory) &&
    Array.isArray(state.shuffleStartHistory) &&
    Array.isArray(state.playedUserQueueHistory) &&
    typeof state.isInUserQueue === "boolean" &&
    typeof state.isShuffleActive === "boolean" &&
    (state.loopState === "off" ||
      state.loopState === "one" ||
      state.loopState === "all") &&
    typeof state.currentTime === "number" &&
    typeof state.duration === "number"
  );
}
