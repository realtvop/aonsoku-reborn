import { pathToFileURL } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NativeAudioMetadata } from "@aonsoku/audio-contract";
import { NativeAudioService } from "./service";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineEvent,
  DesktopAudioEngineEventListener,
  DesktopAudioEngineLoadOptions,
} from "./types";

class FakeAudioEngine implements DesktopAudioEngine {
  readonly load = vi.fn(async (_options: DesktopAudioEngineLoadOptions) => {});
  readonly play = vi.fn(async () => {});
  readonly pause = vi.fn(async () => {});
  readonly stop = vi.fn(async () => {});
  readonly seek = vi.fn(async (_position: number) => {});
  readonly clear = vi.fn(async () => {});
  readonly updateMetadata = vi.fn(
    async (_metadata: NativeAudioMetadata) => {},
  );
  readonly listeners = new Set<DesktopAudioEngineEventListener>();

  onEvent(listener: DesktopAudioEngineEventListener): () => void {
    this.listeners.add(listener);

    return () => {
      this.listeners.delete(listener);
    };
  }

  emit(event: DesktopAudioEngineEvent): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }
}

describe("NativeAudioService", () => {
  let engine: FakeAudioEngine;
  let service: NativeAudioService;

  beforeEach(() => {
    engine = new FakeAudioEngine();
    service = new NativeAudioService({ engine });
  });

  it("loads stream, radio, and native-file sources through the engine", async () => {
    await service.load({
      requestId: "request-stream",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-1",
        songId: "song-1",
      },
      metadata: {
        title: "Track",
        duration: 123,
      },
      autoplay: true,
      startTime: 12,
    });
    await service.load({
      source: {
        kind: "radio",
        url: "https://radio.example/live",
        radioId: "radio-1",
      },
    });
    await service.load({
      source: {
        kind: "native-file",
        uri: pathToFileURL("/tmp/aonsoku-song.mp3").toString(),
        songId: "song-2",
      },
    });

    expect(engine.load).toHaveBeenNthCalledWith(1, {
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
    expect(engine.load).toHaveBeenNthCalledWith(2, {
      source: {
        kind: "radio",
        target: "https://radio.example/live",
      },
      metadata: undefined,
      autoplay: undefined,
      startTime: undefined,
    });
    expect(engine.load).toHaveBeenNthCalledWith(3, {
      source: {
        kind: "native-file",
        target: "/tmp/aonsoku-song.mp3",
      },
      metadata: undefined,
      autoplay: undefined,
      startTime: undefined,
    });
  });

  it("rejects blob sources with a clear unsupported-source error", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await expect(
      service.load({
        requestId: "request-blob",
        source: {
          kind: "blob",
          url: "blob:https://app/audio",
          songId: "song-blob",
        },
      }),
    ).rejects.toThrow("Desktop native audio does not support blob sources yet.");

    expect(engine.load).not.toHaveBeenCalled();
    expect(events).toEqual([
      {
        eventName: "playbackStateChanged",
        event: {
          requestId: "request-blob",
          state: "failed",
        },
      },
      {
        eventName: "error",
        event: {
          requestId: "request-blob",
          code: "unsupported-source",
          message: "Desktop native audio does not support blob sources yet.",
        },
      },
    ]);
  });

  it("forwards base engine events with the active request id", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.load({
      requestId: "request-1",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-1",
      },
    });

    engine.emit({
      type: "playbackStateChanged",
      state: "playing",
    });
    engine.emit({
      type: "progress",
      currentTime: 11,
      duration: 100,
      bufferedTime: 20,
    });
    engine.emit({
      type: "durationChanged",
      duration: 100,
    });
    engine.emit({
      type: "bufferingChanged",
      isBuffering: false,
    });
    engine.emit({
      type: "ended",
      reason: "finished",
    });
    engine.emit({
      type: "error",
      code: "mpv-playback-error",
      message: "mpv playback error",
    });

    expect(events).toEqual([
      {
        eventName: "playbackStateChanged",
        event: {
          requestId: "request-1",
          state: "playing",
        },
      },
      {
        eventName: "progress",
        event: {
          requestId: "request-1",
          currentTime: 11,
          duration: 100,
          bufferedTime: 20,
        },
      },
      {
        eventName: "durationChanged",
        event: {
          requestId: "request-1",
          duration: 100,
        },
      },
      {
        eventName: "bufferingChanged",
        event: {
          requestId: "request-1",
          isBuffering: false,
        },
      },
      {
        eventName: "ended",
        event: {
          requestId: "request-1",
          reason: "finished",
        },
      },
      {
        eventName: "error",
        event: {
          requestId: "request-1",
          code: "mpv-playback-error",
          message: "mpv playback error",
        },
      },
    ]);
  });

  it("dispatches the supported playback controls to the engine", async () => {
    await service.play();
    await service.pause();
    await service.stop();
    await service.seek({ position: -5 });
    await service.setRepeatMode({ mode: "all" });
    await service.setShuffle({ enabled: true });
    await service.clear();
    await service.updateMetadata({ title: "Updated title" });
    await service.setVolumeHUDEnabled({ enabled: false });
    await service.setLikeActive({ active: true });

    expect(engine.play).toHaveBeenCalledTimes(1);
    expect(engine.pause).toHaveBeenCalledTimes(1);
    expect(engine.stop).toHaveBeenCalledTimes(1);
    expect(engine.seek).toHaveBeenCalledWith(0);
    expect(engine.clear).toHaveBeenCalledTimes(1);
    expect(engine.updateMetadata).toHaveBeenCalledWith({
      title: "Updated title",
    });
  });

  it("tracks native queue controls and skips through queued songs", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.setContextQueue({
      songs: [
        {
          id: "song-1",
          title: "First",
          artist: "Artist",
          album: "Album",
          duration: 100,
          streamUrl: "https://server/rest/stream?id=song-1",
        },
        {
          id: "song-2",
          title: "Second",
          artist: "Artist",
          album: "Album",
          duration: 120,
          streamUrl: "https://server/rest/stream?id=song-2",
        },
      ],
      currentIndex: 0,
      autoplay: true,
    });

    expect(service.getControlState()).toEqual({
      isPlaying: false,
      hasCurrent: true,
      hasNativeQueue: true,
      hasPrevious: false,
      hasNext: true,
    });
    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-1",
      },
      metadata: {
        title: "First",
        artist: "Artist",
        album: "Album",
        duration: 100,
        artworkUrl: undefined,
      },
      autoplay: true,
      startTime: undefined,
    });

    await expect(service.handleRemoteCommand("next")).resolves.toBe(true);

    expect(service.getControlState()).toEqual({
      isPlaying: false,
      hasCurrent: true,
      hasNativeQueue: true,
      hasPrevious: true,
      hasNext: false,
    });
    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-2",
      },
      metadata: {
        title: "Second",
        artist: "Artist",
        album: "Album",
        duration: 120,
        artworkUrl: undefined,
      },
      autoplay: true,
      startTime: undefined,
    });
    expect(events).toContainEqual({
      eventName: "queueStateChanged",
      event: {
        requestId: "desktop-native-queue-2",
        currentIndex: 1,
        songId: "song-2",
        reason: "next",
        isInUserQueue: false,
      },
    });
  });

  it("handles play toggles natively only after audio is loaded", async () => {
    await expect(
      service.handleRemoteCommand("togglePlayPause"),
    ).resolves.toBe(false);

    await service.load({
      requestId: "request-1",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-1",
      },
    });
    engine.emit({
      type: "playbackStateChanged",
      state: "playing",
    });

    await expect(
      service.handleRemoteCommand("togglePlayPause"),
    ).resolves.toBe(true);
    expect(engine.pause).toHaveBeenCalledTimes(1);
  });

  it("emits contract remote commands for renderer fallback", () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    service.emitRemoteCommand("previous");

    expect(events).toEqual([
      {
        eventName: "remoteCommand",
        event: {
          requestId: undefined,
          command: "previous",
        },
      },
    ]);
  });
});
