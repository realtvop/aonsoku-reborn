import type { NativeFullState } from "@aonsoku/audio-contract";
import type { DesktopPlaybackStateStorage } from "./playback-state-store";

const FULL_STATE_DEBOUNCE_MS = 500;
const PROGRESS_SAVE_INTERVAL_MS = 5_000;
const MEANINGFUL_PROGRESS_SECONDS = 0.5;

export class DesktopPlaybackStatePersistence {
  readonly #storage: DesktopPlaybackStateStorage;
  readonly #stateProvider: () => NativeFullState;
  #fullStateTimer: ReturnType<typeof setTimeout> | null = null;
  #progressTimer: ReturnType<typeof setTimeout> | null = null;
  #lastSavedProgress = 0;
  #pendingProgress = 0;
  #lastProgressSaveAt = Date.now();
  #fullStateDirty = false;
  #epoch = 0;
  #cleared = false;

  constructor(
    storage: DesktopPlaybackStateStorage,
    stateProvider: () => NativeFullState,
  ) {
    this.#storage = storage;
    this.#stateProvider = stateProvider;
  }

  restored(state: NativeFullState): void {
    this.#cleared = false;
    this.#lastSavedProgress = state.currentTime;
    this.#pendingProgress = state.currentTime;
    this.#lastProgressSaveAt = Date.now();
  }

  markStateDirty(): void {
    this.#cleared = false;
    this.#fullStateDirty = true;
    this.#cancelFullStateTimer();
    const epoch = this.#epoch;
    this.#fullStateTimer = setTimeout(() => {
      this.#fullStateTimer = null;
      if (epoch !== this.#epoch) return;
      this.#saveLatest();
    }, FULL_STATE_DEBOUNCE_MS);
  }

  updateProgress(currentTime: number): void {
    if (this.#cleared) return;
    this.#pendingProgress = currentTime;
    if (
      Math.abs(currentTime - this.#lastSavedProgress) <=
      MEANINGFUL_PROGRESS_SECONDS
    ) {
      return;
    }
    if (this.#progressTimer) return;

    const elapsed = Date.now() - this.#lastProgressSaveAt;
    const delay = Math.max(0, PROGRESS_SAVE_INTERVAL_MS - elapsed);
    const epoch = this.#epoch;
    this.#progressTimer = setTimeout(() => {
      this.#progressTimer = null;
      if (epoch !== this.#epoch) return;
      if (
        Math.abs(this.#pendingProgress - this.#lastSavedProgress) <=
        MEANINGFUL_PROGRESS_SECONDS
      ) {
        return;
      }
      if (!this.#fullStateDirty) this.#saveLatest();
    }, delay);
  }

  async flush(): Promise<void> {
    this.#cancelTimers();
    if (this.#cleared) return;
    await this.#saveLatest();
  }

  async clear(): Promise<void> {
    this.#epoch += 1;
    this.#cancelTimers();
    this.#fullStateDirty = false;
    this.#lastSavedProgress = 0;
    this.#pendingProgress = 0;
    this.#lastProgressSaveAt = Date.now();
    this.#cleared = true;
    try {
      await this.#storage.clear();
    } catch {
      // Persistence is best effort and must never interrupt playback.
    }
  }

  #saveLatest(): Promise<void> {
    try {
      const state = this.#stateProvider();
      this.#fullStateDirty = false;
      this.#lastSavedProgress = state.currentTime;
      this.#pendingProgress = state.currentTime;
      this.#lastProgressSaveAt = Date.now();
      return Promise.resolve(this.#storage.save(state)).catch(() => {});
    } catch {
      return Promise.resolve();
    }
  }

  #cancelTimers(): void {
    this.#cancelFullStateTimer();
    if (this.#progressTimer) clearTimeout(this.#progressTimer);
    this.#progressTimer = null;
  }

  #cancelFullStateTimer(): void {
    if (this.#fullStateTimer) clearTimeout(this.#fullStateTimer);
    this.#fullStateTimer = null;
  }
}
