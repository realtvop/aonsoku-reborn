import { beforeEach, describe, expect, it, vi } from "vitest";
import { usePlaybackReplacementStore } from "@/store/playback-replacement.store";
import { LoopState } from "@/types/playerContext";
import { createQueueActions } from "./queue-actions";

const mocks = vi.hoisted(() => ({
  seekPlaybackTarget: vi.fn(),
}));

vi.mock("@/player/playback/backend-registry", () => ({
  seekPlaybackTarget: mocks.seekPlaybackTarget,
}));

vi.mock("@/player/queue-controller", () => ({
  getNativeQueueController: () => null,
}));

function makeSong(id: string) {
  return {
    id,
    title: id,
    album: "album",
    artist: "artist",
    duration: 120,
  };
}

function makeState() {
  const currentSong = makeSong("a");

  return {
    playerState: {
      audioPlayerRef: { currentTime: 5 },
      isPlaying: false,
      isTransitioning: false,
      loopState: LoopState.Off,
      currentDuration: 120,
    },
    playerProgress: {
      progress: 2,
      bufferedProgress: 10,
    },
    songlist: {
      currentSong,
      contextQueue: {
        songs: [currentSong],
        currentIndex: 0,
        sourceId: null,
        sourceName: null,
      },
      sourceQueue: {
        songs: [currentSong],
        currentIndex: 0,
        sourceId: null,
        sourceName: null,
      },
      userQueue: { songs: [] },
      isInUserQueue: false,
      playedUserQueueHistory: [],
      isShuffleActive: false,
      shuffleHistory: [],
      shuffleStartHistory: [],
      originalContextSongs: [],
      originalUserSongs: [],
      radioList: [],
    },
  };
}

describe("queue actions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    usePlaybackReplacementStore.getState().reset();
  });

  it("restarts the current song when previous is used without a real previous song", () => {
    const state = makeState();
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.playPrevSong?.();

    expect(state.playerProgress.progress).toBe(0);
    expect(state.playerProgress.bufferedProgress).toBe(0);
    expect(state.songlist.contextQueue.currentIndex).toBe(0);
    expect(mocks.seekPlaybackTarget).toHaveBeenCalledWith(
      state.playerState.audioPlayerRef,
      0,
    );
  });

  it("adds play-next songs before the existing user queue", () => {
    const state = makeState();
    state.songlist.userQueue.songs = [makeSong("queued")];
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setNextOnQueue?.([makeSong("next")]);

    expect(state.songlist.userQueue.songs.map((song) => song.id)).toEqual([
      "next",
      "queued",
    ]);
  });

  it("keeps the current user-queue song first when adding play-next songs", () => {
    const state = makeState();
    state.songlist.isInUserQueue = true;
    state.songlist.userQueue.songs = [makeSong("current"), makeSong("queued")];
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setNextOnQueue?.([makeSong("next-1"), makeSong("next-2")]);

    expect(state.songlist.userQueue.songs.map((song) => song.id)).toEqual([
      "current",
      "next-1",
      "next-2",
      "queued",
    ]);
  });

  it("requests confirmation before replacing a non-empty context queue", () => {
    const state = makeState();
    state.playerState.isPlaying = true;
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setSongList?.([makeSong("replacement")], 0, false, {
      albumId: "album-2",
    });

    expect(state.songlist.contextQueue.songs[0]?.id).toBe("a");
    expect(usePlaybackReplacementStore.getState().request).toMatchObject({
      kind: "songList",
      songs: [{ id: "replacement" }],
      sourceId: { albumId: "album-2" },
    });
  });

  it("replaces the context queue after confirmation", () => {
    const state = makeState();
    state.playerState.isPlaying = true;
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setSongList?.(
      [makeSong("replacement")],
      0,
      false,
      { albumId: "album-2" },
      "Album 2",
      { bypassQueueConfirmation: true },
    );

    expect(state.songlist.contextQueue.songs[0]?.id).toBe("replacement");
    expect(state.songlist.contextQueue.sourceId).toEqual({
      type: "album",
      id: "album-2",
    });
  });

  it("requests confirmation before replacing the queue with one song", () => {
    const state = makeState();
    state.playerState.isPlaying = true;
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });
    Object.assign(state, { actions });

    actions.playSong?.(makeSong("replacement"));

    expect(state.songlist.contextQueue.songs[0]?.id).toBe("a");
    expect(usePlaybackReplacementStore.getState().request).toMatchObject({
      kind: "song",
      song: { id: "replacement" },
    });
  });

  it("replaces and starts a new context queue without confirmation when paused", () => {
    const state = makeState();
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });

    actions.setSongList?.([makeSong("replacement")], 0, false, {
      albumId: "album-2",
    });

    expect(usePlaybackReplacementStore.getState().request).toBeNull();
    expect(state.songlist.contextQueue.songs[0]?.id).toBe("replacement");
    expect(state.playerState.isPlaying).toBe(true);
  });

  it("replaces and starts a new song without confirmation when paused", () => {
    const state = makeState();
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => false,
      remoteSend: vi.fn(),
      clearSonglistState: vi.fn(),
    });
    Object.assign(state, { actions });

    actions.playSong?.(makeSong("replacement"));

    expect(usePlaybackReplacementStore.getState().request).toBeNull();
    expect(state.songlist.contextQueue.songs[0]?.id).toBe("replacement");
    expect(state.playerState.isPlaying).toBe(true);
  });
});
