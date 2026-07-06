import { describe, expect, it, vi } from "vitest";
import { LibMpvAudioEngine } from "./libmpv-engine";
import type {
  MpvPlayer,
  MpvPlayerEvent,
  MpvPlayerEventListener,
  MpvPlayerInitializeOptions,
  MpvPropertyFormat,
  MpvPropertyValue,
} from "./mpv-player";
import type { DesktopAudioEngineEvent } from "./types";

class FakeMpvPlayer implements MpvPlayer {
  readonly initialize = vi.fn(
    async (_options: MpvPlayerInitializeOptions) => {},
  );
  readonly command = vi.fn(async (_args: readonly string[]) => {});
  readonly setProperty = vi.fn(
    async (_name: string, _value: MpvPropertyValue) => {},
  );
  readonly observeProperty = vi.fn(
    async (_name: string, _format: MpvPropertyFormat) => {},
  );
  readonly destroy = vi.fn(async () => {});
  readonly listeners = new Set<MpvPlayerEventListener>();

  onEvent(listener: MpvPlayerEventListener): () => void {
    this.listeners.add(listener);

    return () => {
      this.listeners.delete(listener);
    };
  }

  emit(event: MpvPlayerEvent): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }
}

function createHarness(): {
  engine: LibMpvAudioEngine;
  events: DesktopAudioEngineEvent[];
  player: FakeMpvPlayer;
} {
  const player = new FakeMpvPlayer();
  const engine = new LibMpvAudioEngine({ playerFactory: () => player });
  const events: DesktopAudioEngineEvent[] = [];
  engine.onEvent((event) => events.push(event));

  return { engine, events, player };
}

describe("LibMpvAudioEngine", () => {
  it("initializes libmpv, observes properties, and loads streams", async () => {
    const { engine, events, player } = createHarness();

    await engine.load({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-1",
      },
      metadata: {
        title: "Track",
        duration: 123,
      },
      autoplay: true,
      startTime: 12,
    });

    expect(player.initialize).toHaveBeenCalledWith({
      options: {
        "audio-display": "no",
        "force-window": "no",
        idle: "yes",
        terminal: "no",
        vid: "no",
      },
    });
    expect(player.observeProperty.mock.calls).toEqual([
      ["time-pos", "number"],
      ["duration", "number"],
      ["pause", "boolean"],
      ["paused-for-cache", "boolean"],
      ["cache-buffering-state", "number"],
    ]);
    expect(player.setProperty.mock.calls).toEqual([
      ["pause", false],
      ["force-media-title", "Track"],
    ]);
    expect(player.command.mock.calls).toEqual([
      [["loadfile", "https://server/rest/stream?id=song-1", "replace"]],
      [["seek", "12", "absolute", "exact"]],
    ]);
    expect(events).toEqual([
      { type: "playbackStateChanged", state: "loading" },
      { type: "bufferingChanged", isBuffering: true },
      {
        type: "progress",
        currentTime: 12,
        duration: 123,
        bufferedTime: 12,
      },
    ]);
  });

  it("maps libmpv file and property events to contract engine events", async () => {
    const { engine, events, player } = createHarness();

    await engine.load({
      source: {
        kind: "radio",
        target: "https://radio.example/live",
      },
    });
    player.emit({ type: "file-loaded" });
    player.emit({ type: "property-change", name: "duration", data: 45 });
    player.emit({ type: "property-change", name: "time-pos", data: 11 });
    player.emit({ type: "property-change", name: "pause", data: false });
    player.emit({
      type: "property-change",
      name: "paused-for-cache",
      data: true,
    });
    player.emit({
      type: "property-change",
      name: "cache-buffering-state",
      data: 100,
    });
    player.emit({ type: "end-file", reason: "eof" });

    expect(events).toEqual([
      { type: "playbackStateChanged", state: "loading" },
      { type: "bufferingChanged", isBuffering: true },
      { type: "bufferingChanged", isBuffering: false },
      { type: "playbackStateChanged", state: "paused" },
      {
        type: "progress",
        currentTime: 0,
        duration: 0,
        bufferedTime: 0,
      },
      { type: "durationChanged", duration: 45 },
      {
        type: "progress",
        currentTime: 0,
        duration: 45,
        bufferedTime: 0,
      },
      {
        type: "progress",
        currentTime: 11,
        duration: 45,
        bufferedTime: 11,
      },
      { type: "playbackStateChanged", state: "playing" },
      { type: "bufferingChanged", isBuffering: true },
      { type: "bufferingChanged", isBuffering: false },
      { type: "bufferingChanged", isBuffering: false },
      { type: "playbackStateChanged", state: "ended" },
      { type: "ended", reason: "finished" },
    ]);
  });

  it("suppresses libmpv stop events caused by repeat load and explicit stop", async () => {
    const { engine, events, player } = createHarness();

    await engine.load({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-1",
      },
      autoplay: true,
    });
    player.emit({ type: "file-loaded" });
    await engine.load({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-2",
      },
      autoplay: true,
    });
    player.emit({ type: "end-file", reason: "stop" });
    await engine.stop();
    player.emit({ type: "end-file", reason: "stop" });

    expect(player.command.mock.calls).toContainEqual([
      ["loadfile", "https://server/rest/stream?id=song-2", "replace"],
    ]);
    expect(events).toContainEqual({
      type: "playbackStateChanged",
      state: "stopped",
    });
    expect(events).toContainEqual({ type: "ended", reason: "stopped" });
    expect(
      events.filter(
        (event) => event.type === "ended" && event.reason === "stopped",
      ),
    ).toHaveLength(1);
  });

  it("sets player volume through the mpv volume property", async () => {
    const { engine, player } = createHarness();

    await engine.setVolume(1.25);
    await engine.setVolume(-1);
    await engine.setVolume(Number.NaN);

    expect(player.setProperty.mock.calls).toContainEqual(["volume", 100]);
    expect(player.setProperty.mock.calls).toContainEqual(["volume", 0]);
    expect(player.setProperty.mock.calls).toContainEqual(["volume", 100]);
  });

  it("maps libmpv playback errors and command failures", async () => {
    const { engine, events, player } = createHarness();

    await engine.load({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-1",
      },
    });
    player.emit({
      type: "end-file",
      reason: "error",
      error: "demuxer failed",
    });

    player.command.mockRejectedValueOnce(new Error("bad seek"));
    await expect(engine.seek(5)).rejects.toMatchObject({
      code: "mpv-command-failed",
      message: "bad seek",
    });
    expect(events).toContainEqual({
      type: "error",
      code: "mpv-playback-error",
      message: "demuxer failed",
    });
  });

  it("cleans up players when initialization or observers fail", async () => {
    const initFailure = new FakeMpvPlayer();
    initFailure.initialize.mockRejectedValueOnce(new Error("bad init"));
    const initEngine = new LibMpvAudioEngine({
      playerFactory: () => initFailure,
    });

    await expect(
      initEngine.load({
        source: {
          kind: "stream",
          target: "https://server/rest/stream?id=song-1",
        },
      }),
    ).rejects.toMatchObject({
      code: "mpv-init-failed",
      message: "bad init",
    });
    expect(initFailure.destroy).toHaveBeenCalledTimes(1);

    const observerFailure = new FakeMpvPlayer();
    observerFailure.observeProperty.mockRejectedValueOnce(
      new Error("bad observe"),
    );
    const observerEngine = new LibMpvAudioEngine({
      playerFactory: () => observerFailure,
    });

    await expect(
      observerEngine.load({
        source: {
          kind: "stream",
          target: "https://server/rest/stream?id=song-1",
        },
      }),
    ).rejects.toMatchObject({
      code: "mpv-observer-failed",
      message: "bad observe",
    });
    expect(observerFailure.destroy).toHaveBeenCalledTimes(1);
  });

  it("normalizes player creation failures", async () => {
    const engine = new LibMpvAudioEngine({
      playerFactory: () => {
        throw new Error("addon missing");
      },
    });

    await expect(
      engine.load({
        source: {
          kind: "stream",
          target: "https://server/rest/stream?id=song-1",
        },
      }),
    ).rejects.toMatchObject({
      code: "libmpv-unavailable",
      message: "addon missing",
    });
  });

  it("preflights libmpv initialization without keeping a player alive", async () => {
    const { engine, player } = createHarness();

    await expect(engine.checkAvailability()).resolves.toEqual({
      backend: "libmpv",
      status: "available",
      platformKey: `${process.platform}-${process.arch}`,
    });
    expect(player.initialize).toHaveBeenCalledTimes(1);
    expect(player.observeProperty).toHaveBeenCalledTimes(5);
    expect(player.destroy).toHaveBeenCalledTimes(1);
  });

  it("releases the player and ignores late events after destroy", async () => {
    const { engine, events, player } = createHarness();

    await engine.load({
      source: {
        kind: "native-file",
        target: "/tmp/song.mp3",
      },
    });
    await engine.destroy();
    player.emit({ type: "file-loaded" });

    expect(player.destroy).toHaveBeenCalledTimes(1);
    expect(player.listeners.size).toBe(0);
    expect(events).toEqual([
      { type: "playbackStateChanged", state: "loading" },
      { type: "bufferingChanged", isBuffering: true },
    ]);
  });
});
