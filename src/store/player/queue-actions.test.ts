import { beforeEach, describe, expect, it, vi } from "vitest";
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
});
