import type { NativeFullState } from "@aonsoku/audio-contract";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DesktopPlaybackStatePersistence } from "./playback-state-persistence";
import type { DesktopPlaybackStateStorage } from "./playback-state-store";

describe("DesktopPlaybackStatePersistence", () => {
  let currentState: NativeFullState;
  let storage: DesktopPlaybackStateStorage;
  let persistence: DesktopPlaybackStatePersistence;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(10_000);
    currentState = fullState();
    storage = {
      load: vi.fn(() => null),
      save: vi.fn(async () => {}),
      clear: vi.fn(async () => {}),
    };
    persistence = new DesktopPlaybackStatePersistence(
      storage,
      () => currentState,
    );
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("throttles high-frequency progress and ignores insignificant changes", async () => {
    for (let second = 1; second <= 4; second += 1) {
      currentState = fullState(second);
      persistence.updateProgress(second);
      await vi.advanceTimersByTimeAsync(1_000);
    }
    expect(storage.save).not.toHaveBeenCalled();

    currentState = fullState(5);
    persistence.updateProgress(5);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(storage.save).toHaveBeenCalledTimes(1);
    expect(storage.save).toHaveBeenLastCalledWith(
      expect.objectContaining({ currentTime: 5 }),
    );

    currentState = fullState(5.4);
    persistence.updateProgress(5.4);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(storage.save).toHaveBeenCalledTimes(1);
  });

  it("debounces structural changes and saves the latest state", async () => {
    persistence.markStateDirty();
    await vi.advanceTimersByTimeAsync(400);
    currentState = { ...fullState(12), loopState: "all" };
    persistence.markStateDirty();
    await vi.advanceTimersByTimeAsync(499);
    expect(storage.save).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(storage.save).toHaveBeenCalledTimes(1);
    expect(storage.save).toHaveBeenCalledWith(currentState);
  });

  it("flushes only the latest state", async () => {
    persistence.markStateDirty();
    currentState = { ...fullState(33), isShuffleActive: true };

    await persistence.flush();
    await vi.advanceTimersByTimeAsync(500);

    expect(storage.save).toHaveBeenCalledTimes(1);
    expect(storage.save).toHaveBeenCalledWith(currentState);
  });

  it("clear cancels pending work and cannot be revived by flush or progress", async () => {
    persistence.markStateDirty();
    persistence.updateProgress(10);
    await persistence.clear();
    currentState = fullState(20);
    persistence.updateProgress(20);
    await vi.advanceTimersByTimeAsync(10_000);
    await persistence.flush();

    expect(storage.clear).toHaveBeenCalledTimes(1);
    expect(storage.save).not.toHaveBeenCalled();
  });

  it("isolates storage failures from flush and clear", async () => {
    storage.save = vi.fn(async () => {
      throw new Error("disk full");
    });
    storage.clear = vi.fn(async () => {
      throw new Error("permission denied");
    });

    await expect(persistence.flush()).resolves.toBeUndefined();
    await expect(persistence.clear()).resolves.toBeUndefined();
  });
});

function fullState(currentTime = 0): NativeFullState {
  return {
    contextQueue: {
      songs: [],
      currentIndex: -1,
      sourceId: null,
      sourceName: null,
    },
    userQueue: [],
    originalContextSongs: [],
    originalUserSongs: [],
    shuffleHistory: [],
    shuffleStartHistory: [],
    playedUserQueueHistory: [],
    isInUserQueue: false,
    isShuffleActive: false,
    loopState: "off",
    isPlaying: false,
    currentTime,
    duration: 100,
    currentSongId: null,
    isRestored: false,
  };
}
