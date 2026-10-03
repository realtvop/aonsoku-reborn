import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PlaybackSnapshot } from "@/coordination/types";
import { usePlaybackReplacementStore } from "@/store/playback-replacement.store";
import { LanControlMessageType } from "@/types/lanControl";
import { LoopState } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";
import { createQueueActions } from "./queue-actions";

const mocks = vi.hoisted(() => ({
  seekPlaybackTarget: vi.fn(),
  useNative: false,
  nativeController: {
    play: vi.fn(),
    setSongList: vi.fn(),
    playSong: vi.fn(),
  },
}));

vi.mock("@/player/playback/backend-registry", () => ({
  seekPlaybackTarget: mocks.seekPlaybackTarget,
}));

vi.mock("@/player/queue-controller", () => ({
  getNativeQueueController: () =>
    mocks.useNative ? mocks.nativeController : null,
}));

function makeSong(id: string): ISong {
  return {
    id,
    title: id,
    album: "album",
    artist: "artist",
    duration: 120,
  } as ISong;
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
      userQueue: { songs: [] as ISong[] },
      isInUserQueue: false,
      playedUserQueueHistory: [] as ISong[],
      isShuffleActive: false,
      shuffleHistory: [],
      shuffleStartHistory: [],
      originalContextSongs: [],
      originalUserSongs: [],
      radioList: [],
    },
  };
}

function setup(remoteSnapshot?: PlaybackSnapshot) {
  const state = makeState();
  const remoteSend = vi.fn(() => !!remoteSnapshot);
  const actions = createQueueActions({
    set: (fn) => fn(state as never),
    get: () => state as never,
    isRemoteActive: () => !!remoteSnapshot,
    remoteSend,
    getRemotePlaybackTarget: () =>
      remoteSnapshot ? { deviceId: "remote", snapshot: remoteSnapshot } : null,
    clearSonglistState: vi.fn(),
  });
  return { state, actions, remoteSend };
}

function makeSnapshot(overrides: Partial<PlaybackSnapshot> = {}) {
  return {
    songId: "remote-current",
    isPlaying: true,
    contextQueue: ["remote-current", "remote-next"],
    contextIndex: 0,
    userQueue: ["manual"],
    sourceId: null,
    inUserQueue: false,
    shuffle: false,
    ...overrides,
  } as PlaybackSnapshot;
}

describe("queue actions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.useNative = false;
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

  it("requests confirmation before discarding remaining manual songs", () => {
    const state = makeState();
    state.playerState.isPlaying = true;
    state.songlist.userQueue.songs = [makeSong("manual")];
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
    state.songlist.userQueue.songs = [makeSong("manual")];
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
    expect(state.songlist.userQueue.songs).toEqual([]);
  });

  it("requests confirmation before replacing the queue with one song", () => {
    const state = makeState();
    state.playerState.isPlaying = true;
    state.songlist.userQueue.songs = [makeSong("manual")];
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
    state.songlist.userQueue.songs = [makeSong("manual")];
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
    state.songlist.userQueue.songs = [makeSong("manual")];
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

describe.each(["web", "native"])(
  "queue replacement on %s playback",
  (backend) => {
    beforeEach(() => {
      vi.clearAllMocks();
      mocks.useNative = backend === "native";
      usePlaybackReplacementStore.getState().reset();
    });

    it.each([false, true])(
      "starts a new list without manual songs (shuffle=%s)",
      (shuffle) => {
        const { state, actions } = setup();
        state.playerState.isPlaying = true;
        actions.setSongList([makeSong("b"), makeSong("c")], 0, shuffle);
        expect(usePlaybackReplacementStore.getState().open).toBe(false);
        if (mocks.useNative) {
          expect(mocks.nativeController.setSongList).toHaveBeenCalled();
        } else {
          expect(state.songlist.contextQueue.songs[0].id).toBe("b");
        }
      },
    );

    it("starts another single song without manual songs", () => {
      const { state, actions } = setup();
      state.playerState.isPlaying = true;
      actions.playSong(makeSong("b"));
      expect(usePlaybackReplacementStore.getState().open).toBe(false);
      if (mocks.useNative)
        expect(mocks.nativeController.playSong).toHaveBeenCalled();
      else expect(state.songlist.contextQueue.songs[0].id).toBe("b");
    });

    it.each(["song", "list", "shuffle"])(
      "protects a manual-only queue before %s playback",
      (intent) => {
        const { state, actions } = setup();
        state.playerState.isPlaying = true;
        state.songlist.contextQueue.songs = [];
        state.songlist.sourceQueue.songs = [];
        state.songlist.userQueue.songs = [
          makeSong("current"),
          makeSong("manual"),
        ];
        state.songlist.isInUserQueue = true;
        if (intent === "song") actions.playSong(makeSong("b"));
        else actions.setSongList([makeSong("b")], 0, intent === "shuffle");
        expect(usePlaybackReplacementStore.getState().open).toBe(true);
        expect(state.songlist.userQueue.songs).toHaveLength(2);
        expect(mocks.nativeController.setSongList).not.toHaveBeenCalled();
        expect(mocks.nativeController.playSong).not.toHaveBeenCalled();
      },
    );

    it("does not protect the manual song already playing when no others remain", () => {
      const { state, actions } = setup();
      state.playerState.isPlaying = true;
      state.songlist.isInUserQueue = true;
      state.songlist.userQueue.songs = [makeSong("current")];
      actions.playSong(makeSong("b"));
      expect(usePlaybackReplacementStore.getState().open).toBe(false);
    });

    it.each([false, true])(
      "resumes the same context without replacing it (playing=%s)",
      (playing) => {
        const { state, actions } = setup();
        state.playerState.isPlaying = playing;
        state.songlist.userQueue.songs = [makeSong("manual")];
        actions.setSongList([makeSong("a")], 0);
        expect(usePlaybackReplacementStore.getState().open).toBe(false);
        expect(state.songlist.userQueue.songs[0].id).toBe("manual");
        expect(state.playerProgress.progress).toBe(2);
        expect(mocks.nativeController.setSongList).not.toHaveBeenCalled();
        if (mocks.useNative)
          expect(mocks.nativeController.play).toHaveBeenCalled();
        else expect(state.playerState.isPlaying).toBe(true);
      },
    );

    it("protects manual songs when the same song is selected from a different context", () => {
      const { state, actions } = setup();
      state.playerState.isPlaying = true;
      state.songlist.userQueue.songs = [makeSong("manual")];
      actions.setSongList([makeSong("a")], 0, false, { albumId: "new" });
      expect(usePlaybackReplacementStore.getState().open).toBe(true);
    });

    it("resumes the current single song while retaining manual songs and progress", () => {
      const { state, actions } = setup();
      state.playerState.isPlaying = true;
      state.songlist.userQueue.songs = [makeSong("manual")];
      actions.playSong(makeSong("a"));
      expect(usePlaybackReplacementStore.getState().open).toBe(false);
      expect(state.songlist.userQueue.songs[0].id).toBe("manual");
      expect(state.playerProgress.progress).toBe(2);
      expect(mocks.nativeController.playSong).not.toHaveBeenCalled();
    });
  },
);

describe("remote queue replacement", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.useNative = true;
    usePlaybackReplacementStore.getState().reset();
  });

  it.each(["song", "list", "shuffle"])(
    "confirms %s replacement against the controlled queue",
    (intent) => {
      const { state, actions, remoteSend } = setup(makeSnapshot());
      state.playerState.isPlaying = false;
      if (intent === "song") actions.playSong(makeSong("b"));
      else actions.setSongList([makeSong("b")], 0, intent === "shuffle");
      expect(usePlaybackReplacementStore.getState().request).toMatchObject({
        targetDeviceId: "remote",
      });
      expect(remoteSend).not.toHaveBeenCalled();
      expect(mocks.nativeController.setSongList).not.toHaveBeenCalled();
      expect(mocks.nativeController.playSong).not.toHaveBeenCalled();
    },
  );

  it.each([
    { isPlaying: false },
    { userQueue: [] },
    { inUserQueue: true, userQueue: ["remote-current"] },
  ])(
    "does not protect the local queue when the target needs no confirmation (%j)",
    (overrides) => {
      const { state, actions, remoteSend } = setup(makeSnapshot(overrides));
      state.playerState.isPlaying = true;
      state.songlist.userQueue.songs = [makeSong("local-manual")];
      actions.playSong(makeSong("b"));
      expect(usePlaybackReplacementStore.getState().open).toBe(false);
      expect(remoteSend).toHaveBeenCalledWith(LanControlMessageType.PLAY_SONG, {
        songId: "b",
      });
      expect(state.songlist.userQueue.songs[0].id).toBe("local-manual");
    },
  );

  it("sends a confirmed album replacement while preserving local playback", () => {
    const { state, actions, remoteSend } = setup(makeSnapshot());
    actions.setSongList(
      [makeSong("b")],
      0,
      false,
      { albumId: "new" },
      undefined,
      { bypassQueueConfirmation: true },
    );
    expect(remoteSend).toHaveBeenCalledWith(LanControlMessageType.PLAY_ALBUM, {
      albumId: "new",
      songIndex: 0,
    });
    expect(state.songlist.contextQueue.songs[0].id).toBe("a");
  });

  it("resumes the current remote context without dropping manual songs", () => {
    const { actions, remoteSend } = setup(makeSnapshot());
    actions.setSongList(
      [makeSong("remote-current"), makeSong("remote-next")],
      0,
    );
    expect(usePlaybackReplacementStore.getState().open).toBe(false);
    expect(remoteSend).toHaveBeenCalledExactlyOnceWith(
      LanControlMessageType.PLAY,
    );
  });

  it("preserves insertion position and exact selected songs for remote queue additions", () => {
    const { actions, remoteSend } = setup(makeSnapshot());
    actions.setNextOnQueue([makeSong("selected-tail")], { albumId: "album" });
    actions.setLastOnQueue([makeSong("last")]);
    expect(usePlaybackReplacementStore.getState().open).toBe(false);
    expect(remoteSend.mock.calls).toEqual([
      [
        LanControlMessageType.ADD_TO_QUEUE,
        { songIds: ["selected-tail"], position: "next" },
      ],
      [
        LanControlMessageType.ADD_TO_QUEUE,
        { songIds: ["last"], position: "last" },
      ],
    ]);
  });
});
