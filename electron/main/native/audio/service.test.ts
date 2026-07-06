import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { NativeAudioMetadata } from "@aonsoku/audio-contract";
import { audioCacheDirectoryFromUserDataPath, audioCacheId } from "./cache";
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
  readonly updateMetadata = vi.fn(async (_metadata: NativeAudioMetadata) => {});
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
  let audioCacheDirectory: string;

  beforeEach(async () => {
    audioCacheDirectory = await fs.mkdtemp(
      path.join(tmpdir(), "aonsoku-audio-service-"),
    );
    engine = new FakeAudioEngine();
    service = new NativeAudioService({ engine, audioCacheDirectory });
  });

  afterEach(async () => {
    await fs.rm(audioCacheDirectory, { force: true, recursive: true });
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
    ).rejects.toThrow(
      "Desktop native audio does not support blob sources yet.",
    );

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

  it("stores, resolves, sizes, deletes, and loads cached audio files", async () => {
    const songId = "song/cache-1";
    const data = Buffer.from("cached audio bytes");
    const cacheId = audioCacheId(songId);

    const stored = await service.storeAudioFile({
      songId,
      dataBase64: data.toString("base64"),
      contentType: "audio/mpeg; charset=binary",
    });

    const expectedAudioPath = path.join(audioCacheDirectory, `${cacheId}.mp3`);
    const expectedMetadataPath = path.join(
      audioCacheDirectory,
      `${cacheId}.json`,
    );
    const metadata = JSON.parse(
      await fs.readFile(expectedMetadataPath, "utf8"),
    ) as Record<string, unknown>;

    expect(stored).toEqual({
      songId,
      uri: pathToFileURL(expectedAudioPath).toString(),
      contentType: "audio/mpeg; charset=binary",
      sizeBytes: data.byteLength,
      lastModifiedAt: expect.any(Number),
    });
    expect(metadata).toEqual({
      songId,
      fileName: `${cacheId}.mp3`,
      contentType: "audio/mpeg; charset=binary",
      lastModifiedAt: stored.lastModifiedAt,
    });
    expect(await fs.readFile(fileURLToPath(stored.uri), "utf8")).toBe(
      "cached audio bytes",
    );

    await expect(service.resolveAudioFile({ songId })).resolves.toEqual({
      file: stored,
    });
    await expect(service.getAudioFileSize({ songId })).resolves.toEqual({
      sizeBytes: data.byteLength,
    });

    await service.load({
      requestId: "request-cached",
      source: {
        kind: "native-file",
        uri: stored.uri,
        songId,
      },
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "native-file",
        target: expectedAudioPath,
      },
      metadata: undefined,
      autoplay: undefined,
      startTime: undefined,
    });

    const replacement = await service.storeAudioFile({
      songId,
      dataBase64: Buffer.from("replacement").toString("base64"),
      contentType: "audio/flac",
    });

    expect(fileURLToPath(replacement.uri)).toBe(
      path.join(audioCacheDirectory, `${cacheId}.flac`),
    );
    await expect(fs.access(expectedAudioPath)).rejects.toThrow();

    await expect(service.deleteAudioFile({ songId })).resolves.toEqual({
      deleted: true,
    });
    await expect(service.resolveAudioFile({ songId })).resolves.toEqual({
      file: null,
    });
    await expect(service.getAudioFileSize({ songId })).resolves.toEqual({
      sizeBytes: null,
    });
    await expect(service.deleteAudioFile({ songId })).resolves.toEqual({
      deleted: false,
    });
  });

  it("clears cached audio files without leaking outside the cache directory", async () => {
    await service.storeAudioFile({
      songId: "song-1",
      dataBase64: Buffer.from("one").toString("base64"),
      contentType: "audio/mpeg",
    });
    await service.storeAudioFile({
      songId: "song-2",
      dataBase64: Buffer.from("two").toString("base64"),
      contentType: "audio/ogg",
    });

    await expect(service.clearAudioFiles()).resolves.toEqual({
      deletedCount: 2,
    });
    await expect(fs.readdir(audioCacheDirectory)).resolves.toEqual([]);
  });

  it("derives the default desktop cache directory below Electron userData", () => {
    expect(
      audioCacheDirectoryFromUserDataPath(path.join("tmp", "user-data")),
    ).toBe(path.join("tmp", "user-data", "AudioCache"));
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
    await expect(service.handleRemoteCommand("togglePlayPause")).resolves.toBe(
      false,
    );

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

    await expect(service.handleRemoteCommand("togglePlayPause")).resolves.toBe(
      true,
    );
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
