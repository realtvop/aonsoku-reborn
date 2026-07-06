import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NativeQueueSong } from "@aonsoku/audio-contract";
import {
  DesktopQueueEngine,
  type DesktopQueueEngineDelegate,
} from "./queue-engine";

describe("DesktopQueueEngine", () => {
  let engine: DesktopQueueEngine;
  let delegate: DesktopQueueEngineDelegate;

  beforeEach(() => {
    engine = new DesktopQueueEngine({ random: () => 0 });
    delegate = {
      queueEngineLoadSong: vi.fn(),
      queueEngineDidAdvanceTo: vi.fn(),
      queueEngineDidChangeContents: vi.fn(),
      queueEngineDidExhaustQueue: vi.fn(),
      queueEngineSeekToStart: vi.fn(),
    };
    engine.delegate = delegate;
  });

  it("sets a context queue and exports NativeFullState", () => {
    const songs = [song("1"), song("2")];

    engine.setContextQueue({
      songs,
      currentIndex: 99,
      autoplay: false,
      startTime: 12,
      sourceId: { type: "album", id: "album-1" },
      sourceName: "Album One",
      repeatMode: "all",
    });

    expect(engine.currentIndex).toBe(1);
    expect(engine.currentSong?.id).toBe("2");
    expect(delegate.queueEngineLoadSong).toHaveBeenCalledWith(
      engine,
      expect.objectContaining({ id: "2" }),
      false,
      12,
    );
    expect(engine.getFullState(fullStateOptions())).toEqual({
      contextQueue: {
        songs,
        currentIndex: 1,
        sourceId: { type: "album", id: "album-1" },
        sourceName: "Album One",
      },
      userQueue: [],
      originalContextSongs: [],
      originalUserSongs: [],
      shuffleHistory: [],
      shuffleStartHistory: [],
      playedUserQueueHistory: [],
      isInUserQueue: false,
      isShuffleActive: false,
      loopState: "all",
      isPlaying: true,
      currentTime: 5,
      duration: 100,
      currentSongId: "2",
      isRestored: false,
    });
  });

  it("updates context queue contents or advances when the current song changes", () => {
    engine.setContextQueue({
      songs: [song("1"), song("2")],
      currentIndex: 0,
    });
    vi.mocked(delegate.queueEngineLoadSong).mockClear();

    engine.updateContextQueue([song("1"), song("2"), song("3")], 0);

    expect(delegate.queueEngineDidChangeContents).toHaveBeenCalledWith(
      engine,
      "queue-edit",
    );
    expect(delegate.queueEngineLoadSong).not.toHaveBeenCalled();

    engine.updateContextQueue([song("1"), song("3")], 1);

    expect(delegate.queueEngineLoadSong).toHaveBeenCalledWith(
      engine,
      expect.objectContaining({ id: "3" }),
      true,
      undefined,
    );
    expect(delegate.queueEngineDidAdvanceTo).toHaveBeenCalledWith(
      engine,
      1,
      "3",
      "skip",
    );
  });

  it("plays inserted user queue songs before resuming context queue", () => {
    engine.setContextQueue({
      songs: [song("1"), song("2")],
      currentIndex: 0,
    });
    engine.addToUserQueue([song("A"), song("B")], "next");

    engine.skipToNext();
    expect(engine.isInUserQueue).toBe(true);
    expect(engine.currentSong?.id).toBe("A");
    expect(engine.userQueue.map((item) => item.id)).toEqual(["A", "B"]);

    engine.skipToNext();
    expect(engine.isInUserQueue).toBe(true);
    expect(engine.currentSong?.id).toBe("B");
    expect(engine.userQueue.map((item) => item.id)).toEqual(["B"]);
    expect(engine.playedUserQueueHistory.map((item) => item.id)).toEqual([
      "A",
    ]);

    engine.skipToNext();
    expect(engine.isInUserQueue).toBe(false);
    expect(engine.currentSong?.id).toBe("2");
    expect(engine.userQueue).toEqual([]);
    expect(engine.playedUserQueueHistory.map((item) => item.id)).toEqual([
      "A",
      "B",
    ]);
  });

  it("walks backward through played user queue history", () => {
    engine.setContextQueue({
      songs: [song("1"), song("2")],
      currentIndex: 0,
    });
    engine.addToUserQueue([song("A")], "last");
    engine.skipToNext();
    engine.skipToNext();

    expect(engine.currentSong?.id).toBe("2");

    engine.skipToPrevious(0);

    expect(engine.isInUserQueue).toBe(true);
    expect(engine.currentIndex).toBe(0);
    expect(engine.currentSong?.id).toBe("A");
    expect(engine.userQueue.map((item) => item.id)).toEqual(["A"]);
    expect(delegate.queueEngineDidAdvanceTo).toHaveBeenLastCalledWith(
      engine,
      0,
      "A",
      "previous",
    );
  });

  it("seeks to start on previous when playback is past the threshold", () => {
    engine.setContextQueue({
      songs: [song("1"), song("2")],
      currentIndex: 1,
    });

    engine.skipToPrevious(4);

    expect(engine.currentIndex).toBe(1);
    expect(delegate.queueEngineSeekToStart).toHaveBeenCalledWith(
      engine,
      expect.objectContaining({ id: "2" }),
    );
  });

  it("handles repeat one, repeat all, and queue exhaustion", () => {
    engine.setContextQueue({
      songs: [song("1"), song("2")],
      currentIndex: 1,
    });
    engine.setLoopState("one");

    engine.handleEnded();

    expect(delegate.queueEngineSeekToStart).toHaveBeenCalledWith(
      engine,
      expect.objectContaining({ id: "2" }),
    );

    engine.addToUserQueue([song("A")], "last");
    engine.handleEnded();

    expect(engine.isInUserQueue).toBe(true);
    expect(engine.currentSong?.id).toBe("A");

    engine.clear();
    engine.delegate = delegate;
    engine.setContextQueue({
      songs: [song("1"), song("2")],
      currentIndex: 1,
    });
    engine.setLoopState("all");
    engine.handleEnded();

    expect(engine.currentIndex).toBe(0);
    expect(engine.currentSong?.id).toBe("1");

    engine.setLoopState("off");
    engine.currentIndex = 1;
    engine.handleEnded();

    expect(delegate.queueEngineDidExhaustQueue).toHaveBeenCalledWith(engine);
  });

  it("reorders and clears queue contents", () => {
    engine.setContextQueue({
      songs: [song("1"), song("2"), song("3")],
      currentIndex: 0,
    });

    engine.reorderContextQueue(0, 2);
    expect(engine.contextSongs.map((item) => item.id)).toEqual([
      "2",
      "3",
      "1",
    ]);

    engine.addToUserQueue([song("A"), song("B")], "last");
    engine.removeFromUserQueue([0, 99]);
    expect(engine.userQueue.map((item) => item.id)).toEqual(["B"]);

    engine.clearUserQueue();
    expect(engine.userQueue).toEqual([]);
    expect(engine.playedUserQueueHistory).toEqual([]);
  });

  it("shuffles upcoming context songs and restores original order", () => {
    const songs = [song("1"), song("2"), song("3"), song("4")];
    engine.setContextQueue({
      songs,
      currentIndex: 1,
    });
    engine.addToUserQueue([song("A"), song("B")], "last");

    engine.setShuffleActive(true);

    expect(engine.isShuffleActive).toBe(true);
    expect(engine.originalContextSongs.map((item) => item.id)).toEqual([
      "1",
      "2",
      "3",
      "4",
    ]);
    expect(engine.contextSongs.slice(0, 2).map((item) => item.id)).toEqual([
      "1",
      "2",
    ]);
    expect(engine.contextSongs.slice(2).map((item) => item.id).sort()).toEqual([
      "3",
      "4",
    ]);
    expect(engine.shuffleStartHistory).toEqual(["2"]);
    expect(delegate.queueEngineDidChangeContents).toHaveBeenLastCalledWith(
      engine,
      "shuffle",
    );

    engine.setShuffleActive(false);

    expect(engine.isShuffleActive).toBe(false);
    expect(engine.currentIndex).toBe(1);
    expect(engine.contextSongs).toEqual(songs);
    expect(engine.userQueue.map((item) => item.id)).toEqual(["A", "B"]);
    expect(engine.shuffleHistory).toEqual([]);
    expect(delegate.queueEngineDidChangeContents).toHaveBeenLastCalledWith(
      engine,
      "unshuffle",
    );
  });

  it("marks an already shuffled queue without changing the current order", () => {
    engine.setContextQueue({
      songs: [song("2"), song("1")],
      currentIndex: 0,
    });

    engine.markAsShuffled([song("1"), song("2")]);

    expect(engine.isShuffleActive).toBe(true);
    expect(engine.contextSongs.map((item) => item.id)).toEqual(["2", "1"]);
    expect(engine.originalContextSongs.map((item) => item.id)).toEqual([
      "1",
      "2",
    ]);
  });
});

function song(id: string): NativeQueueSong {
  return {
    id,
    title: `Title ${id}`,
    artist: "Artist",
    album: "Album",
    duration: 100,
    coverArtId: `cover-${id}`,
    streamUrl: `https://server/rest/stream?id=${id}`,
  };
}

function fullStateOptions() {
  return {
    currentTime: 5,
    duration: 100,
    isPlaying: true,
  };
}
