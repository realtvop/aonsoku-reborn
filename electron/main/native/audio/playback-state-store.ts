import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import type { NativeFullState } from "@aonsoku/audio-contract";
import { getDefaultDesktopScrobbleStorageDirectory } from "./scrobble-buffer";

export class DesktopPlaybackStateStore {
  readonly #filePath: string | null;

  constructor(storageDirectory = getDefaultDesktopScrobbleStorageDirectory()) {
    this.#filePath = storageDirectory
      ? path.join(storageDirectory, "playback-state.json")
      : null;
  }

  load(): NativeFullState | null {
    if (!this.#filePath || !existsSync(this.#filePath)) return null;
    try {
      const value = JSON.parse(readFileSync(this.#filePath, "utf8"));
      return isNativeFullState(value) ? value : null;
    } catch {
      return null;
    }
  }

  save(state: NativeFullState): void {
    if (!this.#filePath) return;
    try {
      mkdirSync(path.dirname(this.#filePath), { recursive: true });
      const temporaryPath = `${this.#filePath}.${process.pid}.tmp`;
      writeFileSync(temporaryPath, JSON.stringify(state), "utf8");
      renameSync(temporaryPath, this.#filePath);
    } catch {
      // Persistence is best effort and must never interrupt playback.
    }
  }

  clear(): void {
    if (!this.#filePath) return;
    try {
      writeFileSync(this.#filePath, "", "utf8");
    } catch {
      // See save().
    }
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
