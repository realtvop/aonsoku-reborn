import { beforeEach, describe, expect, it, vi } from "vitest";
import { LanControlMessageType } from "@/types/lanControl";
import { LoopState } from "@/types/playerContext";
import { createPlaybackActions } from "./playback-actions";
import { createQueueActions } from "./queue-actions";

function makeSong(id: string) {
  return {
    id,
    title: id,
    album: "album",
    artist: "artist",
    duration: 120,
  };
}

const mocks = vi.hoisted(() => ({
  nativeController: {
    playNext: vi.fn(),
    seek: vi.fn(),
  },
}));

vi.mock("@/player/queue-controller", () => ({
  getNativeQueueController: () => mocks.nativeController,
}));

function makeState() {
  return {
    playerState: {
      isPlaying: false,
      loopState: LoopState.Off,
    },
    playerProgress: {
      progress: 0,
      seekCount: 0,
    },
    songlist: {
      contextQueue: {
        songs: [],
        currentIndex: 0,
        sourceId: null,
        sourceName: null,
      },
      sourceQueue: {
        songs: [],
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
      radioList: [],
    },
  };
}

describe("remote control actions on native runtimes", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("sends playback commands remotely before using the native controller", () => {
    const state = makeState();
    const remoteSend = vi.fn(() => true);
    const actions = createPlaybackActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => true,
      remoteSend,
    });

    actions.setProgress?.(42, true);

    expect(remoteSend).toHaveBeenCalledWith(LanControlMessageType.SEEK, {
      seconds: 42,
    });
    expect(mocks.nativeController.seek).not.toHaveBeenCalled();
    expect(state.playerProgress.progress).toBe(42);
    expect(state.playerProgress.seekCount).toBe(1);
  });

  it("sends queue commands remotely before using the native controller", () => {
    const state = makeState();
    const remoteSend = vi.fn(() => true);
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => true,
      remoteSend,
      clearSonglistState: vi.fn(),
    });

    actions.playNextSong?.();

    expect(remoteSend).toHaveBeenCalledWith(LanControlMessageType.NEXT);
    expect(mocks.nativeController.playNext).not.toHaveBeenCalled();
  });

  it("does not mutate the local queue when sending a remote song list", () => {
    const state = makeState();
    const localSong = makeSong("local-song");
    state.songlist.contextQueue.songs = [localSong];
    state.songlist.contextQueue.sourceName = "Local Album";
    state.songlist.isShuffleActive = false;
    const remoteSend = vi.fn(() => true);
    const actions = createQueueActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => true,
      remoteSend,
      clearSonglistState: vi.fn(),
    });

    actions.setSongList?.([makeSong("remote-song")], 0, true, undefined);

    expect(remoteSend).toHaveBeenCalledWith(
      LanControlMessageType.CLEAR_QUEUE,
    );
    expect(state.songlist.contextQueue.songs).toEqual([localSong]);
    expect(state.songlist.contextQueue.sourceName).toBe("Local Album");
    expect(state.songlist.isShuffleActive).toBe(false);
    expect(state.playerState.isPlaying).toBe(true);
  });

  it("does not rebuild the local queue when toggling remote repeat", () => {
    const state = makeState();
    const localSong = makeSong("local-song");
    state.songlist.contextQueue.songs = [localSong];
    state.playerState.loopState = LoopState.Off;
    const remoteSend = vi.fn(() => true);
    const actions = createPlaybackActions({
      set: (fn) => fn(state as never),
      get: () => state as never,
      isRemoteActive: () => true,
      remoteSend,
    });

    actions.toggleLoop?.();

    expect(remoteSend).toHaveBeenCalledWith(LanControlMessageType.TOGGLE_REPEAT);
    expect(state.songlist.contextQueue.songs).toEqual([localSong]);
    expect(state.playerState.loopState).toBe(LoopState.Off);
  });
});
