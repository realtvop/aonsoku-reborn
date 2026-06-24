import { beforeEach, describe, expect, it, vi } from "vitest";
import { LanControlMessageType } from "@/types/lanControl";
import { LoopState } from "@/types/playerContext";
import { createPlaybackActions } from "./playback-actions";
import { createQueueActions } from "./queue-actions";

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
});
