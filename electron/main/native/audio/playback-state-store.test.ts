import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { NativeFullState } from "@aonsoku/audio-contract";
import { afterEach, describe, expect, it } from "vitest";
import { DesktopPlaybackStateStore } from "./playback-state-store";

describe("DesktopPlaybackStateStore", () => {
  const directories: string[] = [];

  afterEach(async () => {
    await Promise.all(
      directories
        .splice(0)
        .map((directory) => fs.rm(directory, { force: true, recursive: true })),
    );
  });

  it("serializes writes in call order and atomically exposes the latest state", async () => {
    const directory = await temporaryDirectory();
    const store = new DesktopPlaybackStateStore(directory);

    await Promise.all([store.save(fullState(1)), store.save(fullState(2))]);

    expect(store.load()).toMatchObject({ currentTime: 2 });
    expect(await fs.readdir(directory)).toEqual(["playback-state.json"]);
  });

  it("clears after earlier writes and leaves no state to restore", async () => {
    const directory = await temporaryDirectory();
    const store = new DesktopPlaybackStateStore(directory);

    await Promise.all([store.save(fullState(1)), store.clear()]);

    expect(store.load()).toBeNull();
    expect(await fs.readdir(directory)).toEqual([]);
  });

  it("isolates filesystem failures from callers", async () => {
    const directory = await temporaryDirectory();
    const invalidDirectory = path.join(directory, "not-a-directory");
    await fs.writeFile(invalidDirectory, "file", "utf8");
    const store = new DesktopPlaybackStateStore(invalidDirectory);

    await expect(store.save(fullState(1))).resolves.toBeUndefined();
    await expect(store.clear()).resolves.toBeUndefined();
    expect(store.load()).toBeNull();
  });

  async function temporaryDirectory(): Promise<string> {
    const directory = await fs.mkdtemp(
      path.join(tmpdir(), "aonsoku-playback-state-"),
    );
    directories.push(directory);
    return directory;
  }
});

function fullState(currentTime: number): NativeFullState {
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
