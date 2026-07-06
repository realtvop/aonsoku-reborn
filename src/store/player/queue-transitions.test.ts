import { describe, expect, it } from "vitest";
import type {
  IContextQueue,
  ISongList,
  QueueSourceId,
} from "@/types/playerContext";
import { LoopState } from "@/types/playerContext";
import type { Radio } from "@/types/responses/radios";
import type { ISong } from "@/types/responses/song";
import {
  PREV_SEEK_THRESHOLD,
  transitionClearUserQueue,
  transitionEnterUserQueueMode,
  transitionHandleSongEnded,
  transitionNextSong,
  transitionPlayFromQueue,
  transitionPlaySong,
  transitionPrevSong,
  transitionRemoveFromContextQueue,
  transitionRemoveFromUserQueue,
  transitionReorderQueue,
  transitionSetSongList,
  transitionUpdatePrevNextFlags,
} from "./queue-transitions";
import { emptyContextQueue, initSonglistState } from "./queue-utils";

function makeSong(id: string, duration = 180): ISong {
  return { id, duration } as ISong;
}

function makeSonglist(overrides?: Partial<ISongList>): ISongList {
  return {
    ...initSonglistState(),
    ...overrides,
  };
}

function makeContextQueue(
  songs: ISong[],
  currentIndex = 0,
  overrides?: Partial<IContextQueue>,
): IContextQueue {
  return {
    ...emptyContextQueue(),
    songs,
    currentIndex,
    ...overrides,
  };
}

function make3SongList(): ISongList {
  return makeSonglist({
    contextQueue: makeContextQueue(
      [makeSong("a"), makeSong("b"), makeSong("c")],
      0,
    ),
    userQueue: { songs: [] },
  });
}

describe("transitionNextSong", () => {
  it("returns null when there is no next song and loop is off", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [] },
    });
    const result = transitionNextSong(songlist, LoopState.Off);
    expect(result).toBeNull();
  });

  it("advances context queue while preserving playback history", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        0,
      ),
      userQueue: { songs: [] },
    });
    const result = transitionNextSong(songlist, LoopState.Off);
    expect(result).not.toBeNull();
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
    expect(result!.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "a",
      "b",
      "c",
    ]);
    expect(result!.songlist.currentSong?.id).toBe("b");
    expect(result!.resetProgress).toBe(true);
    expect(result!.isTransitioning).toBe(true);
  });

  it("advances to the next song when loop state is One", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [] },
      isInUserQueue: false,
    });
    const result = transitionNextSong(songlist, LoopState.One);
    expect(result).not.toBeNull();
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
    expect(result!.songlist.currentSong?.id).toBe("b");
    expect(result!.seekToStart).toBe(false);
    expect(result!.resetProgress).toBe(true);
    expect(result!.isTransitioning).toBe(true);
  });

  it("appends a new playback cycle at the end with LoopState.All", () => {
    const songlist = makeSonglist({
      sourceQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
      userQueue: { songs: [] },
      isShuffleActive: false,
    });
    const result = transitionNextSong(songlist, LoopState.All);
    expect(result).not.toBeNull();
    expect(result!.songlist.contextQueue.currentIndex).toBe(2);
    expect(result!.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "a",
      "b",
      "a",
      "b",
    ]);
    expect(result!.resetProgress).toBe(true);
  });

  it("enters user queue when not in user queue but user queue has songs", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2")] },
      isInUserQueue: false,
    });
    const result = transitionNextSong(songlist, LoopState.Off);
    expect(result).not.toBeNull();
    expect(result!.songlist.isInUserQueue).toBe(true);
    expect(result!.songlist.currentSong?.id).toBe("u1");
    expect(result!.isTransitioning).toBe(true);
  });

  it("consumes first user queue song when isInUserQueue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2")] },
      isInUserQueue: true,
      playedUserQueueHistory: [],
    });
    const result = transitionNextSong(songlist, LoopState.Off);
    expect(result).not.toBeNull();
    expect(result!.songlist.userQueue.songs.map((s) => s.id)).toEqual(["u2"]);
    expect(result!.songlist.playedUserQueueHistory.map((s) => s.id)).toEqual([
      "u1",
    ]);
    expect(result!.songlist.isInUserQueue).toBe(true);
    expect(result!.songlist.currentSong?.id).toBe("u2");
  });

  it("drops back to context queue when last user song consumed", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        0,
      ),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
      playedUserQueueHistory: [],
    });
    const result = transitionNextSong(songlist, LoopState.Off);
    expect(result).not.toBeNull();
    expect(result!.songlist.userQueue.songs).toHaveLength(0);
    expect(result!.songlist.isInUserQueue).toBe(false);
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
    expect(result!.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "a",
      "b",
      "c",
    ]);
    expect(result!.songlist.currentSong?.id).toBe("b");
  });

  it("wraps context index when last user song consumed at end of context", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
      playedUserQueueHistory: [],
    });
    const result = transitionNextSong(songlist, LoopState.All);
    expect(result).not.toBeNull();
    expect(result!.songlist.isInUserQueue).toBe(false);
    expect(result!.songlist.contextQueue.currentIndex).toBe(2);
  });

  it("advances within user queue without changing context index", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2"), makeSong("u3")] },
      isInUserQueue: true,
    });
    const result = transitionNextSong(songlist, LoopState.Off);
    expect(result!.songlist.contextQueue.currentIndex).toBe(0);
    expect(result!.songlist.userQueue.songs).toHaveLength(2);
    expect(result!.songlist.userQueue.songs[0].id).toBe("u2");
  });
});

describe("transitionPrevSong", () => {
  it("returns seekToStart when progress exceeds threshold", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
    });
    const result = transitionPrevSong(songlist, 5, LoopState.Off);
    expect(result).not.toBeNull();
    expect(result!.seekToStart).toBe(true);
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
  });

  it("does not seek when progress is at or below threshold", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
    });
    const result = transitionPrevSong(
      songlist,
      PREV_SEEK_THRESHOLD,
      LoopState.Off,
    );
    expect(result).not.toBeNull();
    expect(result!.seekToStart).toBe(false);
    expect(result!.songlist.contextQueue.currentIndex).toBe(0);
  });

  it("seeks to start when there is no previous song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      playedUserQueueHistory: [],
    });
    const result = transitionPrevSong(songlist, 0, LoopState.Off);
    expect(result).not.toBeNull();
    expect(result!.seekToStart).toBe(true);
    expect(result!.songlist.contextQueue.currentIndex).toBe(0);
  });

  it("returns null when there is no current song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([], 0),
      playedUserQueueHistory: [],
    });
    const result = transitionPrevSong(songlist, 0, LoopState.Off);
    expect(result).toBeNull();
  });

  it("decrements context index when not in user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        2,
      ),
      playedUserQueueHistory: [],
      isInUserQueue: false,
    });
    const result = transitionPrevSong(songlist, 0, LoopState.Off);
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
    expect(result!.songlist.currentSong?.id).toBe("b");
  });

  it("restores from playedUserQueueHistory", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
      playedUserQueueHistory: [makeSong("u0")],
    });
    const result = transitionPrevSong(songlist, 0, LoopState.Off);
    expect(result!.songlist.userQueue.songs[0].id).toBe("u0");
    expect(result!.songlist.userQueue.songs).toHaveLength(2);
    expect(result!.songlist.isInUserQueue).toBe(true);
    expect(result!.songlist.playedUserQueueHistory).toHaveLength(0);
  });

  it("decrements context index when restoring from history and not in user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: false,
      playedUserQueueHistory: [makeSong("u0")],
    });
    const result = transitionPrevSong(songlist, 0, LoopState.Off);
    expect(result!.songlist.contextQueue.currentIndex).toBe(0);
    expect(result!.songlist.isInUserQueue).toBe(true);
  });

  it("does not decrement context index when restoring from history and already in user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
      playedUserQueueHistory: [makeSong("u0")],
    });
    const result = transitionPrevSong(songlist, 0, LoopState.Off);
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
  });

  it("drops back to context queue from user queue with no history", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
      playedUserQueueHistory: [],
    });
    const result = transitionPrevSong(songlist, 0, LoopState.Off);
    expect(result!.songlist.isInUserQueue).toBe(false);
    expect(result!.songlist.currentSong?.id).toBe("a");
  });
});

describe("transitionRemoveFromContextQueue", () => {
  it("removes a song before current index and adjusts index", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        2,
      ),
      isInUserQueue: false,
    });
    const result = transitionRemoveFromContextQueue(songlist, "a");
    expect(result).not.toBeNull();
    expect(result!.songlist.contextQueue.songs).toHaveLength(2);
    expect(result!.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "b",
      "c",
    ]);
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
  });

  it("removes the currently playing song and uses next as current", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        1,
      ),
      isInUserQueue: false,
    });
    const result = transitionRemoveFromContextQueue(songlist, "b");
    expect(result!.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "a",
      "c",
    ]);
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
    expect(result!.resetProgress).toBe(true);
  });

  it("removes a song after current index without adjusting index", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        0,
      ),
      isInUserQueue: false,
    });
    const result = transitionRemoveFromContextQueue(songlist, "c");
    expect(result!.songlist.contextQueue.currentIndex).toBe(0);
    expect(result!.songlist.contextQueue.songs).toHaveLength(2);
  });

  it("returns null when removing song makes queue empty", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      isInUserQueue: false,
    });
    const result = transitionRemoveFromContextQueue(songlist, "a");
    expect(result).toBeNull();
  });

  it("returns null when song id is not found", () => {
    const songlist = make3SongList();
    const result = transitionRemoveFromContextQueue(songlist, "z");
    expect(result).toBeNull();
  });

  it("adjusts index when in user queue and removing before context index", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        2,
      ),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
    });
    const result = transitionRemoveFromContextQueue(songlist, "a");
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
    expect(result!.resetProgress).toBe(false);
  });

  it("removes from original context songs", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        0,
      ),
      originalContextSongs: [makeSong("a"), makeSong("b"), makeSong("c")],
    });
    const result = transitionRemoveFromContextQueue(songlist, "b");
    expect(result!.songlist.originalContextSongs.map((s) => s.id)).toEqual([
      "a",
      "c",
    ]);
  });
});

describe("transitionRemoveFromUserQueue", () => {
  it("removes a song from user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2")] },
    });
    const result = transitionRemoveFromUserQueue(songlist, "u1");
    expect(result!.songlist.userQueue.songs.map((s) => s.id)).toEqual(["u2"]);
  });

  it("exits user queue when removing the playing song from one-item queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
    });
    const result = transitionRemoveFromUserQueue(songlist, "u1");
    expect(result!.songlist.isInUserQueue).toBe(false);
  });

  it("does not exit user queue when removing non-first song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2")] },
      isInUserQueue: true,
    });
    const result = transitionRemoveFromUserQueue(songlist, "u2");
    expect(result!.songlist.isInUserQueue).toBe(true);
  });

  it("returns null when song id not found", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
    });
    const result = transitionRemoveFromUserQueue(songlist, "z");
    expect(result).toBeNull();
  });
});

describe("transitionReorderQueue", () => {
  it("reorders within user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2"), makeSong("u3")] },
    });
    const result = transitionReorderQueue(songlist, 2, 1);
    expect(result!.songlist.userQueue.songs.map((s) => s.id)).toEqual([
      "u2",
      "u1",
      "u3",
    ]);
  });

  it("reorders within upcoming context songs", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c"), makeSong("d")],
        0,
      ),
      userQueue: { songs: [] },
    });
    const result = transitionReorderQueue(songlist, 1, 3);
    expect(result!.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "a",
      "c",
      "d",
      "b",
    ]);
  });

  it("returns null for cross-tier move from user queue to upcoming context", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1")] },
    });
    const result = transitionReorderQueue(songlist, 1, 2);
    expect(result).toBeNull();
  });

  it("returns null for cross-tier move from upcoming context to user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(
        [makeSong("a"), makeSong("b"), makeSong("c")],
        0,
      ),
      userQueue: { songs: [makeSong("u1")] },
    });
    const result = transitionReorderQueue(songlist, 2, 1);
    expect(result).toBeNull();
  });

  it("returns null when from and to are same", () => {
    const songlist = make3SongList();
    const result = transitionReorderQueue(songlist, 1, 1);
    expect(result).toBeNull();
  });
});

describe("transitionEnterUserQueueMode", () => {
  it("enters user queue at the specified index", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2"), makeSong("u3")] },
    });
    const result = transitionEnterUserQueueMode(songlist, 1);
    expect(result!.songlist.isInUserQueue).toBe(true);
    expect(result!.songlist.userQueue.songs.map((s) => s.id)).toEqual([
      "u2",
      "u3",
    ]);
    expect(result!.songlist.playedUserQueueHistory.map((s) => s.id)).toEqual([
      "u1",
    ]);
    expect(result!.songlist.currentSong?.id).toBe("u2");
    expect(result!.resetProgress).toBe(true);
  });

  it("enters at index 0 with no history", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2")] },
    });
    const result = transitionEnterUserQueueMode(songlist, 0);
    expect(result!.songlist.isInUserQueue).toBe(true);
    expect(result!.songlist.playedUserQueueHistory).toHaveLength(0);
    expect(result!.songlist.currentSong?.id).toBe("u1");
  });

  it("returns null for out-of-range index", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
    });
    const result = transitionEnterUserQueueMode(songlist, 5);
    expect(result).toBeNull();
  });

  it("returns null for negative index", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
    });
    const result = transitionEnterUserQueueMode(songlist, -1);
    expect(result).toBeNull();
  });
});

describe("transitionClearUserQueue", () => {
  it("clears user queue and exits user queue mode", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1"), makeSong("u2")] },
      isInUserQueue: true,
      playedUserQueueHistory: [makeSong("u0")],
    });
    const result = transitionClearUserQueue(songlist);
    expect(result.songlist.userQueue.songs).toEqual([]);
    expect(result.songlist.playedUserQueueHistory).toEqual([]);
    expect(result.songlist.isInUserQueue).toBe(false);
  });

  it("does not set isInUserQueue false when not in user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: false,
    });
    const result = transitionClearUserQueue(songlist);
    expect(result.songlist.isInUserQueue).toBe(false);
  });
});

describe("transitionHandleSongEnded", () => {
  it("returns playNext when there is a next song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      userQueue: { songs: [] },
    });
    const result = transitionHandleSongEnded(songlist, LoopState.Off);
    expect(result).toEqual({ action: "playNext" });
  });

  it("returns seekToStart when loop one and no next context/user songs", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [] },
    });
    const result = transitionHandleSongEnded(songlist, LoopState.One);
    expect(result).toEqual({ action: "seekToStart" });
  });

  it("returns playNext when loop one but user queue has remaining songs", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: false,
    });
    const result = transitionHandleSongEnded(songlist, LoopState.One);
    expect(result).toEqual({ action: "playNext" });
  });

  it("returns stop when at last song with no loop and no user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [] },
    });
    const result = transitionHandleSongEnded(songlist, LoopState.Off);
    expect(result).toEqual({ action: "stop" });
  });

  it("returns playNext when loop all at last song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 1),
      userQueue: { songs: [] },
    });
    const result = transitionHandleSongEnded(songlist, LoopState.All);
    expect(result).toEqual({ action: "playNext" });
  });

  it("returns seekToStart when loop all has only the current song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [] },
    });
    const result = transitionHandleSongEnded(songlist, LoopState.All);
    expect(result).toEqual({ action: "seekToStart" });
  });

  it("returns playNext when loop all has a queued user song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: false,
    });
    const result = transitionHandleSongEnded(songlist, LoopState.All);
    expect(result).toEqual({ action: "playNext" });
  });

  it("seeks to start for loop one when in user queue with no remaining songs", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
    });
    const result = transitionHandleSongEnded(songlist, LoopState.One);
    expect(result).toEqual({ action: "seekToStart" });
  });

  it("returns playNext when loop all is on, we are playing the last user queue song, and context queue has only one song", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
    });
    const result = transitionHandleSongEnded(songlist, LoopState.All);
    expect(result).toEqual({ action: "playNext" });
  });
});

describe("transitionUpdatePrevNextFlags", () => {
  it("returns hasPrev false and hasNext true for first song with multiple context songs", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a"), makeSong("b")], 0),
      playedUserQueueHistory: [],
    });
    const result = transitionUpdatePrevNextFlags(songlist, LoopState.Off);
    expect(result.hasPrev).toBe(false);
    expect(result.hasNext).toBe(true);
  });

  it("returns hasPrev true when in user queue", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      isInUserQueue: true,
      userQueue: { songs: [makeSong("u1")] },
    });
    const result = transitionUpdatePrevNextFlags(songlist, LoopState.Off);
    expect(result.hasPrev).toBe(true);
  });
});

describe("transitionSetSongList", () => {
  const identityShuffle: (items: ISong[], _history: string[]) => ISong[] = (
    items,
  ) => items;
  const pickStartIndex = (
    _len: number,
    _history: string[],
    _idFn: (i: number) => string,
  ) => 0;
  const sourceId: QueueSourceId = { type: "album", id: "test-album" };

  it("sets context queue with songs at given index", () => {
    const songlist = make3SongList();
    const newSongs = [makeSong("x"), makeSong("y"), makeSong("z")];
    const result = transitionSetSongList(
      songlist,
      newSongs,
      1,
      sourceId,
      "Test Album",
      false,
      [],
      identityShuffle,
      pickStartIndex,
    );
    expect(result.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "y",
      "z",
    ]);
    expect(result.songlist.contextQueue.currentIndex).toBe(0);
    expect(result.songlist.contextQueue.sourceId).toEqual(sourceId);
    expect(result.songlist.contextQueue.sourceName).toBe("Test Album");
    expect(result.songlist.isShuffleActive).toBe(false);
    expect(result.songlist.userQueue.songs).toEqual([]);
    expect(result.songlist.isInUserQueue).toBe(false);
    expect(result.resetProgress).toBe(true);
  });

  it("sets shuffle mode with random start", () => {
    const songlist = make3SongList();
    const newSongs = [makeSong("x"), makeSong("y"), makeSong("z")];
    const result = transitionSetSongList(
      songlist,
      newSongs,
      0,
      sourceId,
      null,
      true,
      [],
      identityShuffle,
      pickStartIndex,
    );
    expect(result.songlist.isShuffleActive).toBe(true);
    expect(result.songlist.originalContextSongs).toHaveLength(3);
    expect(result.songlist.contextQueue.currentIndex).toBe(0);
  });

  it("trims large song lists to max window", () => {
    const songlist = make3SongList();
    const bigList = Array.from({ length: 600 }, (_, i) => makeSong(`s${i}`));
    const result = transitionSetSongList(
      songlist,
      bigList,
      300,
      null,
      null,
      false,
      [],
      identityShuffle,
      pickStartIndex,
    );
    expect(result.songlist.contextQueue.songs.length).toBeLessThanOrEqual(500);
  });

  it("clears existing user queue and radio list", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("a")], 0),
      userQueue: { songs: [makeSong("u1")] },
      radioList: [] as Radio[],
      isInUserQueue: true,
      playedUserQueueHistory: [makeSong("old")],
    });
    const newSongs = [makeSong("x"), makeSong("y")];
    const result = transitionSetSongList(
      songlist,
      newSongs,
      0,
      null,
      null,
      false,
      [],
      identityShuffle,
      pickStartIndex,
    );
    expect(result.songlist.userQueue.songs).toEqual([]);
    expect(result.songlist.isInUserQueue).toBe(false);
    expect(result.songlist.playedUserQueueHistory).toEqual([]);
    expect(result.songlist.radioList).toEqual([]);
  });
});

describe("transitionPlayFromQueue", () => {
  it("updates index on same list", () => {
    const songs = [makeSong("a"), makeSong("b"), makeSong("c")];
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(songs, 0),
    });
    const result = transitionPlayFromQueue(songlist, songs, 2, true);
    expect(result!.songlist.contextQueue.currentIndex).toBe(2);
    expect(result!.songlist.isInUserQueue).toBe(false);
    expect(result!.resetProgress).toBe(true);
  });

  it("appends a playback cycle when manually playing the last song with loop all", () => {
    const songs = [makeSong("b"), makeSong("a"), makeSong("c"), makeSong("d")];
    const songlist = makeSonglist({
      sourceQueue: makeContextQueue(songs, 0),
      originalContextSongs: [...songs],
      contextQueue: makeContextQueue(songs, 1),
    });
    const result = transitionPlayFromQueue(
      songlist,
      songs,
      songs.length - 1,
      true,
      LoopState.All,
    );
    expect(result!.songlist.contextQueue.currentIndex).toBe(3);
    expect(result!.songlist.contextQueue.songs.map((song) => song.id)).toEqual([
      "b",
      "a",
      "c",
      "d",
      "b",
      "a",
      "c",
      "d",
    ]);
    expect(result!.songlist.currentSong?.id).toBe("d");
  });

  it("replaces context queue on different list", () => {
    const songlist = makeSonglist({
      contextQueue: makeContextQueue([makeSong("old")], 0),
      userQueue: { songs: [makeSong("u1")] },
      isInUserQueue: true,
    });
    const newSongs = [makeSong("x"), makeSong("y")];
    const result = transitionPlayFromQueue(songlist, newSongs, 0, false);
    expect(result!.songlist.contextQueue.songs.map((s) => s.id)).toEqual([
      "x",
      "y",
    ]);
    expect(result!.songlist.isShuffleActive).toBe(false);
    expect(result!.songlist.isInUserQueue).toBe(false);
    expect(result!.songlist.userQueue.songs).toEqual([]);
  });

  it("returns null for empty list", () => {
    const songlist = make3SongList();
    const result = transitionPlayFromQueue(songlist, [], 0, false);
    expect(result).toBeNull();
  });

  it("clamps out-of-range index", () => {
    const songs = [makeSong("a"), makeSong("b")];
    const songlist = makeSonglist({
      contextQueue: makeContextQueue(songs, 0),
    });
    const result = transitionPlayFromQueue(songlist, songs, 10, true);
    expect(result!.songlist.contextQueue.currentIndex).toBe(1);
  });
});

describe("transitionPlaySong", () => {
  it("creates a single-song context queue", () => {
    const songlist = make3SongList();
    const song = makeSong("solo");
    song.album = "Test Album";
    const result = transitionPlaySong(songlist, song, null);
    expect(result.songlist.contextQueue.songs).toHaveLength(1);
    expect(result.songlist.contextQueue.currentIndex).toBe(0);
    expect(result.songlist.contextQueue.songs[0].id).toBe("solo");
    expect(result.songlist.contextQueue.sourceName).toBe("Test Album");
    expect(result.songlist.userQueue.songs).toEqual([]);
    expect(result.songlist.isShuffleActive).toBe(false);
    expect(result.resetProgress).toBe(true);
  });

  it("uses provided sourceName over song album", () => {
    const songlist = make3SongList();
    const song = makeSong("solo");
    song.album = "Album Name";
    const result = transitionPlaySong(songlist, song, "Custom Name");
    expect(result.songlist.contextQueue.sourceName).toBe("Custom Name");
  });

  it("sets sourceId to null for single song", () => {
    const songlist = make3SongList();
    const result = transitionPlaySong(songlist, makeSong("solo"), null);
    expect(result.songlist.contextQueue.sourceId).toBeNull();
  });
});

describe("PREV_SEEK_THRESHOLD", () => {
  it("is 3 seconds", () => {
    expect(PREV_SEEK_THRESHOLD).toBe(3);
  });
});
