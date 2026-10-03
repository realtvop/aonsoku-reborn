import type { NativeFullState, NativeQueueSong } from "@aonsoku/audio-contract";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type {
  Envelope,
  PlaybackSnapshot,
} from "../../../../src/coordination/types";
import type { NativeAudioService } from "../audio/service";
import type { NativeAudioServiceEvent } from "../audio/types";
import { DesktopCoordinationPlayback } from "./playback";

const queueSong = (id: string): NativeQueueSong => ({
  id,
  title: id,
  artist: "artist",
  album: "album",
  duration: 300,
  streamUrl: `aonsoku-media://stream?id=${id}`,
});
const fullState = (): NativeFullState => ({
  contextQueue: {
    songs: [queueSong("a"), queueSong("b")],
    currentIndex: 0,
    sourceId: null,
    sourceName: null,
  },
  userQueue: [],
  originalContextSongs: [queueSong("a"), queueSong("b")],
  originalUserSongs: [],
  shuffleHistory: [],
  shuffleStartHistory: [],
  playedUserQueueHistory: [],
  isInUserQueue: false,
  isShuffleActive: false,
  loopState: "off",
  isPlaying: false,
  currentTime: 42,
  duration: 300,
  currentSongId: "a",
  isRestored: true,
});
const snapshot = (): PlaybackSnapshot => ({
  sessionId: "source-session",
  logicalPlaybackSessionId: "source-session",
  mediaKind: "song",
  songId: "u",
  progressSeconds: 51,
  durationSeconds: 300,
  isPlaying: true,
  sampledAt: Date.now() / 1000,
  contextQueue: ["a", "b"],
  contextIndex: 1,
  sourceId: null,
  sourceName: "source queue",
  userQueue: ["u", "v"],
  inUserQueue: true,
  restorePrevious: ["p"],
  shuffle: true,
  repeat: "all",
  volume: 0.7,
  accumulatedPlaySeconds: 0,
  historyWritten: false,
  nowPlayingSent: false,
  scrobbleSent: false,
});

describe("desktop native coordination playback", () => {
  let controller: DesktopCoordinationPlayback;
  let state: NativeFullState;
  let listeners: Set<(event: NativeAudioServiceEvent) => void>;
  let audio: ReturnType<typeof makeAudio>;
  const send = vi.fn();
  const saveState = vi.fn();
  const request = vi.fn();

  function notify(event: NativeAudioServiceEvent) {
    for (const listener of listeners) listener(event);
  }
  function makeAudio() {
    return {
      ready: vi.fn().mockResolvedValue(undefined),
      getFullState: vi.fn(async () => structuredClone(state)),
      getSystemVolume: vi.fn(async () => ({ volume: 0.5 })),
      onEvent: vi.fn((listener: (event: NativeAudioServiceEvent) => void) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      }),
      pause: vi.fn(async () => {
        state.isPlaying = false;
        notify({
          eventName: "playbackStateChanged",
          event: { state: "paused" },
        });
      }),
      play: vi.fn(async () => {
        state.isPlaying = true;
        notify({
          eventName: "playbackStateChanged",
          event: { state: "playing" },
        });
      }),
      pauseAndGetFullState: vi.fn(async () => {
        state.isPlaying = false;
        return structuredClone(state);
      }),
      clearRemotePlaybackState: vi.fn().mockResolvedValue(undefined),
      restoreQueueState: vi.fn(
        async (next: NativeFullState, autoplay: boolean) => {
          state = structuredClone(next);
          state.isPlaying = autoplay;
        },
      ),
      setSystemVolume: vi.fn().mockResolvedValue({ volume: 0.7 }),
      clear: vi.fn().mockResolvedValue(undefined),
    };
  }
  function envelope(
    payload: Omit<Envelope, "version" | "messageId">,
  ): Envelope {
    return { version: 1, messageId: "message", ...payload } as Envelope;
  }
  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
    state = fullState();
    listeners = new Set();
    audio = makeAudio();
    controller = new DesktopCoordinationPlayback({
      audio: audio as unknown as NativeAudioService,
      send,
      saveState,
      request,
      cachedSongs: () =>
        ["a", "b", "u", "v", "p"].map((id) => ({ ...queueSong(id) })),
      loadState: () => ({
        sessionId: "desktop-session",
        generation: 1,
        revision: 4,
      }),
    });
    controller.start();
  });
  afterEach(() => {
    controller.destroy();
    vi.useRealTimers();
  });

  it("publishes restored paused queues but stops while controlling or disconnected", async () => {
    await vi.advanceTimersByTimeAsync(100);
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "snapshot",
        sessionId: "desktop-session",
        snapshotRevision: 5,
        snapshot: expect.objectContaining({
          isPlaying: false,
          progressSeconds: 42,
          contextQueue: ["a", "b"],
        }),
      }),
    );
    send.mockClear();
    controller.setControlling(true);
    await vi.advanceTimersByTimeAsync(20_000);
    expect(send).not.toHaveBeenCalled();
    controller.stop();
    controller.setControlling(false);
    await vi.advanceTimersByTimeAsync(20_000);
    expect(send).not.toHaveBeenCalled();
  });

  it("ACKs only after playback settles and does not execute duplicate commands", async () => {
    let release!: () => void;
    audio.pause.mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        }),
    );
    const command = envelope({
      type: "command",
      targetDeviceId: "desktop",
      expectedGeneration: 1,
      command: { type: "pause" },
    });
    const pending = controller.handle(command);
    await Promise.resolve();
    expect(send).not.toHaveBeenCalled();
    release();
    await pending;
    await controller.handle(command);
    expect(audio.pause).toHaveBeenCalledTimes(1);
    expect(
      send.mock.calls.filter(([message]) => message.type === "command_ack"),
    ).toHaveLength(2);
  });

  it("prepares the complete queue paused and adopts the committed session before publishing", async () => {
    const incoming = snapshot();
    await controller.handle(
      envelope({
        type: "handoff_candidate",
        transactionId: "tx",
        sourceDeviceId: "source",
        sessionId: incoming.sessionId,
        snapshot: incoming,
        generation: 1,
        snapshotRevision: 7,
        deadline: Date.now() / 1000 + 30,
      }),
    );
    expect(state).toMatchObject({
      currentTime: 51,
      isPlaying: false,
      isInUserQueue: true,
      isShuffleActive: true,
      loopState: "all",
      userQueue: [{ id: "u" }, { id: "v" }],
      playedUserQueueHistory: [{ id: "p" }],
    });
    expect(audio.setSystemVolume).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "target_ready",
        transactionId: "tx",
        generation: 1,
        snapshotRevision: 7,
      }),
    );
    send.mockClear();
    await vi.advanceTimersByTimeAsync(5000);
    expect(send).not.toHaveBeenCalled();
    await controller.handle(
      envelope({
        type: "handoff_committed",
        transactionId: "tx",
        newGeneration: 2,
        snapshot: { ...incoming, progressSeconds: 55 },
      }),
    );
    expect(state.isPlaying).toBe(true);
    expect(state.currentTime).toBe(55);
    expect(saveState).toHaveBeenCalledWith({
      sessionId: "source-session",
      generation: 2,
      revision: 1,
    });
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "snapshot",
        sessionId: "source-session",
        generation: 2,
        snapshot: expect.objectContaining({
          isPlaying: true,
          userQueue: ["u", "v"],
          restorePrevious: ["p"],
        }),
      }),
    );
  });

  it("pauses and captures the final source state before relinquish acknowledgement", async () => {
    await controller.handle(
      envelope({
        type: "prepare_relinquish",
        sessionId: "desktop-session",
        transactionId: "tx",
        expectedSnapshotRevision: 4,
        deadline: Date.now() / 1000 + 10,
      }),
    );
    expect(audio.pauseAndGetFullState).toHaveBeenCalledOnce();
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "relinquish_ack",
        transactionId: "tx",
        snapshot: expect.objectContaining({
          isPlaying: false,
          progressSeconds: 42,
          sessionId: "desktop-session",
        }),
      }),
    );
  });

  it("restores the prior local queue when a handoff fails", async () => {
    const before = structuredClone(state);
    await controller.handle(
      envelope({
        type: "handoff_candidate",
        transactionId: "tx",
        snapshot: snapshot(),
        generation: 1,
        snapshotRevision: 7,
        deadline: Date.now() / 1000 + 30,
      }),
    );
    await controller.handle(
      envelope({
        type: "handoff_failed",
        transactionId: "tx",
        code: "source_pause_timeout",
      }),
    );
    expect(state).toEqual(before);
  });

  it("pauses a superseded source without publishing another session until explicit playback", async () => {
    await controller.handle(
      envelope({
        type: "session_superseded",
        sessionId: "desktop-session",
        supersededGeneration: 2,
        transferredToDevice: "phone",
      }),
    );
    await vi.advanceTimersByTimeAsync(20_000);
    expect(audio.pause).toHaveBeenCalledOnce();
    expect(send).not.toHaveBeenCalled();
    await audio.play();
    await vi.advanceTimersByTimeAsync(100);
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({ type: "snapshot", generation: 1 }),
    );
    expect(send.mock.calls[0][0].sessionId).not.toBe("desktop-session");
  });

  it("does not send target_ready when a connection changes during metadata preparation", async () => {
    let release!: (value: { data: { song: Record<string, unknown> } }) => void;
    request.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          release = resolve;
        }),
    );
    const incoming = {
      ...snapshot(),
      songId: "missing",
      contextQueue: ["missing"],
      userQueue: [],
      inUserQueue: false,
      restorePrevious: [],
    };
    const preparing = controller.handle(
      envelope({
        type: "handoff_candidate",
        transactionId: "tx",
        snapshot: incoming,
        generation: 1,
        snapshotRevision: 7,
        deadline: Date.now() / 1000 + 30,
      }),
    );
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    controller.stop();
    controller.start();
    release({ data: { song: { ...queueSong("missing") } } });
    await expect(preparing).rejects.toThrow("expired");
    expect(
      send.mock.calls.some(([message]) => message.type === "target_ready"),
    ).toBe(false);
    expect(state.currentSongId).toBe("a");
  });

  it("prepares the transferred queue when its original album is unavailable", async () => {
    request.mockRejectedValueOnce(new Error("album deleted"));
    await controller.handle(
      envelope({
        type: "handoff_candidate",
        transactionId: "tx",
        snapshot: { ...snapshot(), sourceId: "album:deleted" },
        generation: 1,
        snapshotRevision: 7,
        deadline: Date.now() / 1000 + 30,
      }),
    );
    expect(state.originalContextSongs.map((song) => song.id)).toEqual([
      "a",
      "b",
    ]);
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({ type: "target_ready" }),
    );
  });

  it("clears prepared playback after failure when the target was initially empty", async () => {
    state = {
      ...fullState(),
      currentSongId: null,
      contextQueue: { ...fullState().contextQueue, songs: [] },
    };
    await controller.handle(
      envelope({
        type: "handoff_candidate",
        transactionId: "tx",
        snapshot: snapshot(),
        generation: 1,
        snapshotRevision: 7,
        deadline: Date.now() / 1000 + 30,
      }),
    );
    await controller.handle(
      envelope({
        type: "handoff_failed",
        transactionId: "tx",
        code: "source_pause_timeout",
      }),
    );
    expect(audio.clear).toHaveBeenCalledOnce();
  });
});
