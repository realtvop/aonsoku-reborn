import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  NativeAudioEvents,
  NativeAudioPlugin,
} from "@/native/audio/types";
import { LoopState } from "@/types/playerContext";
import { NativeQueueController } from "./native-controller";

type ListenerMap = {
  [TEvent in keyof NativeAudioEvents]?: Array<
    (event: NativeAudioEvents[TEvent]) => void
  >;
};

const mocks = vi.hoisted(() => {
  const mockGetRuntime = vi.fn();
  const listeners: ListenerMap = {};
  const plugin: NativeAudioPlugin = {
    load: vi.fn(async () => {}),
    play: vi.fn(async () => {}),
    pause: vi.fn(async () => {}),
    stop: vi.fn(async () => {}),
    seek: vi.fn(async () => {}),
    setRepeatMode: vi.fn(async () => {}),
    setShuffle: vi.fn(async () => {}),
    setQueue: vi.fn(async () => {}),
    skipToNext: vi.fn(async () => {}),
    skipToPrevious: vi.fn(async () => {}),
    updateMetadata: vi.fn(async () => {}),
    preload: vi.fn(async () => {}),
    clear: vi.fn(async () => {}),
    storeAudioFile: vi.fn(async () => ({
      songId: "song-1",
      uri: "file:///native/song-1.mp3",
    })),
    resolveAudioFile: vi.fn(async () => ({ file: null })),
    getAudioFileSize: vi.fn(async () => ({ sizeBytes: null })),
    deleteAudioFile: vi.fn(async () => ({ deleted: false })),
    clearAudioFiles: vi.fn(async () => ({ deletedCount: 0 })),
    setContextQueue: vi.fn(async () => {}),
    updateContextQueue: vi.fn(async () => {}),
    reorderContextQueue: vi.fn(async () => {}),
    addToUserQueue: vi.fn(async () => {}),
    removeFromUserQueue: vi.fn(async () => {}),
    clearUserQueue: vi.fn(async () => {}),
    playAtIndex: vi.fn(async () => {}),
    markAsShuffled: vi.fn(async () => {}),
    getFullState: vi.fn(async () => ({
      sourceQueue: {
        songs: [],
        currentIndex: 0,
        sourceId: null,
        sourceName: null,
      },
      contextQueue: {
        songs: [],
        currentIndex: 0,
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
      loopState: "off" as const,
      isPlaying: false,
      currentTime: 0,
      duration: 0,
      currentSongId: null,
      isRestored: false,
    })),
    getScrobbleBuffer: vi.fn(async () => ({ entries: [] })),
    clearScrobbleBuffer: vi.fn(async () => {}),
    downloadAudioFile: vi.fn(async () => {}),
    cancelDownload: vi.fn(async () => {}),
    setSystemVolume: vi.fn(async () => {
      throw new Error("not supported");
    }),
    getSystemVolume: vi.fn(async () => {
      throw new Error("not supported");
    }),
    setVolumeHUDEnabled: vi.fn(async () => {}),
    addListener: vi.fn(async (eventName, listener) => {
      listeners[eventName] ??= [];
      listeners[eventName]?.push(listener);
      return {
        remove: vi.fn(async () => {
          listeners[eventName] = listeners[eventName]?.filter(
            (item) => item !== listener,
          );
        }),
      };
    }),
    removeAllListeners: vi.fn(async () => {}),
  };

  const storeState = {
    playerState: {
      loopState: 0,
      isPlaying: true,
      isBuffering: false,
      currentDuration: 123,
      volume: 100,
      mediaType: "song" as const,
    },
    playerProgress: {
      progress: 123,
      bufferedProgress: 123,
    },
    settings: {
      coverArt: {
        useAlbumCoverForSongs: false,
      },
    },
    songlist: {
      sourceQueue: {
        songs: [],
        currentIndex: 0,
        sourceId: undefined,
        sourceName: null,
      },
      contextQueue: {
        songs: [],
        currentIndex: 0,
        sourceId: undefined,
        sourceName: null,
      },
      userQueue: { songs: [] },
      playedUserQueueHistory: [],
      originalContextSongs: [],
      originalUserSongs: undefined,
      shuffleHistory: [],
      shuffleStartHistory: [],
      currentSong: null,
      isInUserQueue: false,
      isShuffleActive: false,
    },
  };

  return {
    mockGetRuntime,
    plugin,
    listeners,
    storeState,
    getNativeAudioPluginAvailability: vi.fn(() => ({
      available: true as const,
      plugin,
    })),
  };
});

vi.mock("@/utils/capabilities", () => ({
  getRuntime: mocks.mockGetRuntime,
}));

vi.mock("@/native/audio/facade", () => ({
  getNativeAudioPluginAvailability: mocks.getNativeAudioPluginAvailability,
}));

vi.mock("@/store/player.store", () => ({
  usePlayerStore: {
    getState: () => mocks.storeState,
    setState: (
      updater:
        | typeof mocks.storeState
        | ((state: typeof mocks.storeState) => void),
    ) => {
      if (typeof updater === "function") {
        updater(mocks.storeState);
        return;
      }
      Object.assign(mocks.storeState, updater);
    },
  },
}));

vi.mock("@/api/httpClient", () => ({
  getSongStreamUrl: (id: string) => `https://example.test/stream/${id}`,
}));

describe("NativeQueueController terminal playback reset", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    for (const value of Object.values(mocks.plugin)) {
      if (typeof value === "function") {
        vi.mocked(value).mockClear();
      }
    }
    for (const key of Object.keys(mocks.listeners) as Array<
      keyof typeof mocks.listeners
    >) {
      delete mocks.listeners[key];
    }
    mocks.storeState.playerState.loopState = LoopState.Off;
    mocks.storeState.playerState.isPlaying = true;
    mocks.storeState.playerState.isBuffering = false;
    mocks.storeState.playerState.currentDuration = 123;
    mocks.storeState.playerState.volume = 100;
    mocks.storeState.playerProgress.progress = 123;
    mocks.storeState.playerProgress.bufferedProgress = 123;
    mocks.storeState.songlist.contextQueue.songs = [];
    mocks.storeState.songlist.contextQueue.currentIndex = 0;
    mocks.storeState.songlist.sourceQueue.songs = [];
    mocks.storeState.songlist.sourceQueue.currentIndex = 0;
    mocks.storeState.songlist.originalContextSongs = [];
    mocks.storeState.songlist.originalUserSongs = undefined;
    mocks.storeState.songlist.userQueue.songs = [];
    mocks.storeState.songlist.playedUserQueueHistory = [];
    mocks.storeState.songlist.shuffleHistory = [];
    mocks.storeState.songlist.shuffleStartHistory = [];
    mocks.storeState.songlist.currentSong = null;
    mocks.storeState.songlist.isInUserQueue = false;
    mocks.storeState.songlist.isShuffleActive = false;
  });

  it("seeks native playback back to zero after the last track ends", async () => {
    const controller = new NativeQueueController();
    await vi.runAllTimersAsync();

    emit("playbackStateChanged", { state: "ended" });
    await vi.advanceTimersByTimeAsync(1000);

    expect(mocks.plugin.seek).toHaveBeenCalledWith({ position: 0 });
    expect(mocks.storeState.playerProgress.progress).toBe(0);
    expect(mocks.storeState.playerProgress.bufferedProgress).toBe(0);
    expect(mocks.storeState.playerState.isPlaying).toBe(false);

    controller.dispose();
  });

  it("does not rewind to zero when native playback advances to the next track", async () => {
    mocks.storeState.songlist.contextQueue.songs = [
      { id: "song-1", duration: 123 } as never,
      { id: "song-2", duration: 234 } as never,
    ];

    const controller = new NativeQueueController();
    await vi.runAllTimersAsync();

    emit("playbackStateChanged", { state: "ended" });
    emit("queueStateChanged", {
      currentIndex: 1,
      songId: "song-2",
      reason: "ended",
    });
    await vi.advanceTimersByTimeAsync(1000);

    expect(mocks.plugin.seek).not.toHaveBeenCalledWith({ position: 0 });
    expect(mocks.storeState.playerProgress.progress).toBe(0);
    expect(mocks.storeState.playerState.isPlaying).toBe(true);

    controller.dispose();
  });
});

describe("NativeQueueController setVolume", () => {
  beforeEach(() => {
    for (const value of Object.values(mocks.plugin)) {
      if (typeof value === "function") {
        vi.mocked(value).mockClear();
      }
    }
  });

  it("calls setSystemVolume on Android", () => {
    mocks.mockGetRuntime.mockReturnValue("capacitor-android");
    const controller = new NativeQueueController();

    controller.setVolume(25);

    expect(mocks.plugin.setSystemVolume).toHaveBeenCalledWith({
      value: 0.25,
    });

    controller.dispose();
  });

  it("routes Electron volume to the desktop player bridge", () => {
    mocks.mockGetRuntime.mockReturnValue("electron");
    const controller = new NativeQueueController();

    controller.setVolume(40);

    expect(mocks.plugin.setSystemVolume).toHaveBeenCalledWith({
      value: 0.4,
    });
    expect(mocks.storeState.playerState.volume).toBe(40);

    controller.dispose();
  });

  it("does not call setSystemVolume on iOS", () => {
    mocks.mockGetRuntime.mockReturnValue("capacitor-ios");
    const controller = new NativeQueueController();

    mocks.plugin.setSystemVolume.mockClear();
    controller.setVolume(50);

    expect(mocks.plugin.setSystemVolume).not.toHaveBeenCalled();

    controller.dispose();
  });

  it("handles setSystemVolume failure gracefully", () => {
    mocks.mockGetRuntime.mockReturnValue("capacitor-android");
    const controller = new NativeQueueController();

    mocks.plugin.setSystemVolume.mockRejectedValue(new Error("plugin error"));
    controller.setVolume(75);

    expect(mocks.plugin.setSystemVolume).toHaveBeenCalledWith({
      value: 0.75,
    });

    controller.dispose();
  });
});

describe("NativeQueueController shuffle and loop queue updates", () => {
  beforeEach(() => {
    for (const value of Object.values(mocks.plugin)) {
      if (typeof value === "function") {
        vi.mocked(value).mockClear();
      }
    }
    mocks.storeState.playerState.loopState = LoopState.Off;
    mocks.storeState.songlist.contextQueue.songs = [
      { id: "song-1", duration: 123 } as never,
      { id: "song-2", duration: 234 } as never,
      { id: "song-3", duration: 345 } as never,
    ];
    mocks.storeState.songlist.contextQueue.currentIndex = 0;
    mocks.storeState.songlist.sourceQueue.songs = [
      ...mocks.storeState.songlist.contextQueue.songs,
    ];
    mocks.storeState.songlist.sourceQueue.currentIndex = 0;
    mocks.storeState.songlist.currentSong =
      mocks.storeState.songlist.contextQueue.songs[0];
    mocks.storeState.songlist.originalContextSongs = [
      ...mocks.storeState.songlist.contextQueue.songs,
    ];
    mocks.storeState.songlist.isShuffleActive = false;
  });

  it("updates native queue without reloading when shuffle is toggled", () => {
    const controller = new NativeQueueController();

    controller.toggleShuffle();

    expect(mocks.plugin.setShuffle).toHaveBeenCalledWith({ enabled: true });
    expect(mocks.plugin.updateContextQueue).toHaveBeenCalledWith({
      songs: expect.arrayContaining([
        expect.objectContaining({ id: "song-1" }),
        expect.objectContaining({ id: "song-2" }),
        expect.objectContaining({ id: "song-3" }),
      ]),
      currentIndex: 0,
    });
    expect(mocks.plugin.setContextQueue).not.toHaveBeenCalled();

    controller.dispose();
  });

  it("sets native shuffle to an explicit target state", () => {
    mocks.storeState.songlist.isShuffleActive = true;
    const controller = new NativeQueueController();

    controller.setShuffleState(false);

    expect(mocks.plugin.setShuffle).toHaveBeenCalledWith({ enabled: false });
    expect(mocks.storeState.songlist.isShuffleActive).toBe(false);
    expect(mocks.plugin.updateContextQueue).toHaveBeenCalled();

    controller.dispose();
  });

  it("updates native queue without reloading when loop state changes", () => {
    const controller = new NativeQueueController();

    controller.setLoopState(LoopState.All);

    expect(mocks.plugin.setRepeatMode).toHaveBeenCalledWith({ mode: "all" });
    expect(mocks.plugin.updateContextQueue).toHaveBeenCalledWith({
      songs: expect.arrayContaining([
        expect.objectContaining({ id: "song-1" }),
        expect.objectContaining({ id: "song-2" }),
        expect.objectContaining({ id: "song-3" }),
      ]),
      currentIndex: 0,
    });
    expect(mocks.plugin.setContextQueue).not.toHaveBeenCalled();

    controller.dispose();
  });
});

describe("NativeQueueController handoff preparation", () => {
  beforeEach(() => {
    for (const value of Object.values(mocks.plugin)) {
      if (typeof value === "function") {
        vi.mocked(value).mockClear();
      }
    }
    mocks.storeState.playerState.loopState = LoopState.All;
    mocks.storeState.songlist.contextQueue.songs = [
      { id: "song-1", title: "Song 1", duration: 123 } as never,
      { id: "song-2", title: "Song 2", duration: 234 } as never,
    ];
    mocks.storeState.songlist.contextQueue.currentIndex = 1;
    mocks.storeState.songlist.contextQueue.sourceId = {
      type: "album",
      id: "album-1",
    };
    mocks.storeState.songlist.contextQueue.sourceName = "Album 1";
  });

  it("syncs the current queue and seeks before resolving", async () => {
    const controller = new NativeQueueController();

    await controller.prepareHandoffPlayback(42, { autoplay: false });

    expect(mocks.plugin.setContextQueue).toHaveBeenCalledWith({
      songs: [
        expect.objectContaining({ id: "song-1" }),
        expect.objectContaining({ id: "song-2" }),
      ],
      currentIndex: 1,
      autoplay: false,
      repeatMode: "all",
      sourceId: { type: "album", id: "album-1" },
      sourceName: "Album 1",
    });
    expect(mocks.plugin.seek).toHaveBeenCalledWith({ position: 42 });

    controller.dispose();
  });
});

function emit<TEvent extends keyof NativeAudioEvents>(
  eventName: TEvent,
  event: NativeAudioEvents[TEvent],
) {
  for (const listener of mocks.listeners[eventName] ?? []) {
    listener(event);
  }
}
