import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type {
  NativeAudioEvents,
  NativeAudioMetadata,
  NativeFullState,
} from "@aonsoku/audio-contract";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { audioCacheDirectoryFromUserDataPath, audioCacheId } from "./cache";
import type { DesktopPlaybackStateStore } from "./playback-state-store";
import { NativeAudioService } from "./service";
import type { DesktopSystemAudioAdapter } from "./system-adapter";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineDiagnostics,
  DesktopAudioEngineEvent,
  DesktopAudioEngineEventListener,
  DesktopAudioEngineLoadOptions,
} from "./types";

class FakeAudioEngine implements DesktopAudioEngine {
  loadImplementation?: (
    options: DesktopAudioEngineLoadOptions,
  ) => void | Promise<void>;
  readonly load = vi.fn(async (options: DesktopAudioEngineLoadOptions) => {
    await this.loadImplementation?.(options);
  });
  readonly play = vi.fn(async () => {});
  readonly pause = vi.fn(async () => {});
  readonly stop = vi.fn(async () => {});
  readonly seek = vi.fn(async (_position: number) => {});
  readonly setVolume = vi.fn(async (_value: number) => {});
  readonly clear = vi.fn(async () => {});
  readonly updateMetadata = vi.fn(async (_metadata: NativeAudioMetadata) => {});
  readonly listeners = new Set<DesktopAudioEngineEventListener>();
  getDiagnostics?: () => DesktopAudioEngineDiagnostics;
  checkAvailability?: () => Promise<DesktopAudioEngineDiagnostics>;

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
    service = new NativeAudioService({
      engine,
      audioCacheDirectory,
      cacheLoadedStreams: false,
    });
  });

  afterEach(async () => {
    service.destroy();
    vi.restoreAllMocks();
    await fs.rm(audioCacheDirectory, { force: true, recursive: true });
  });

  it("waits until ready to restore uncached aonsoku-media queue sources", async () => {
    service.destroy();
    const restoredSong = {
      ...queueSong("restored"),
      coverArtId: "cover-restored",
      streamUrl: "aonsoku-media://stream?id=restored",
    };
    const restoredState: NativeFullState = {
      contextQueue: {
        songs: [restoredSong],
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
      loopState: "off",
      isPlaying: false,
      currentTime: 42,
      duration: 100,
      currentSongId: restoredSong.id,
      isRestored: true,
    };
    const playbackStateStore = {
      load: vi.fn(() => restoredState),
      save: vi.fn(),
      clear: vi.fn(),
    } as unknown as DesktopPlaybackStateStore;
    let streamUrlResolver = (url: string) => url;
    let artworkUrlResolver = (url: string | undefined) => url;

    service = new NativeAudioService({
      engine,
      audioCacheDirectory,
      cacheLoadedStreams: false,
      playbackStateStore,
      deferPlaybackRestore: true,
      streamUrlResolver: (url) => streamUrlResolver(url),
      artworkUrlResolver: (url) => artworkUrlResolver(url),
    });

    expect(playbackStateStore.load).not.toHaveBeenCalled();
    expect(engine.load).not.toHaveBeenCalled();

    streamUrlResolver = () =>
      "https://server/rest/stream.view?id=restored&token=ready";
    artworkUrlResolver = () =>
      "https://server/rest/getCoverArt.view?id=cover-restored&token=ready";
    await Promise.all([service.ready(), service.ready()]);

    expect(playbackStateStore.load).toHaveBeenCalledTimes(1);
    expect(engine.load).toHaveBeenCalledTimes(1);
    expect(engine.load).toHaveBeenCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream.view?id=restored&token=ready",
      },
      metadata: {
        title: restoredSong.title,
        artist: restoredSong.artist,
        album: restoredSong.album,
        duration: restoredSong.duration,
        artworkUrl:
          "https://server/rest/getCoverArt.view?id=cover-restored&token=ready",
      },
      autoplay: false,
      startTime: 42,
    });
  });

  it("resolves artwork URLs through the artworkUrlResolver before loading", async () => {
    const resolvingEngine = new FakeAudioEngine();
    const resolvingService = new NativeAudioService({
      engine: resolvingEngine,
      audioCacheDirectory,
      cacheLoadedStreams: false,
      artworkUrlResolver: (artworkUrl) => {
        if (!artworkUrl) return undefined;
        if (artworkUrl.startsWith("aonsoku-media://")) {
          const parsed = new URL(artworkUrl);
          return `https://server/rest/getCoverArt.view?id=${parsed.searchParams.get("id")}`;
        }
        return `https://server/rest/getCoverArt.view?id=${artworkUrl}`;
      },
    });

    try {
      await resolvingService.load({
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=song-1",
          songId: "song-1",
        },
        metadata: {
          title: "Track",
          duration: 123,
          artworkUrl: "aonsoku-media://getCoverArt?id=art-1&size=300",
        },
        autoplay: true,
      });

      expect(resolvingEngine.load).toHaveBeenLastCalledWith(
        expect.objectContaining({
          metadata: {
            title: "Track",
            duration: 123,
            artworkUrl: "https://server/rest/getCoverArt.view?id=art-1",
          },
        }),
      );

      await resolvingService.updateMetadata({
        title: "Track 2",
        artworkUrl: "mf-1234",
      });

      expect(resolvingEngine.updateMetadata).toHaveBeenLastCalledWith({
        title: "Track 2",
        artworkUrl: "https://server/rest/getCoverArt.view?id=mf-1234",
      });
    } finally {
      resolvingService.destroy();
    }
  });

  it("passes metadata through unchanged when no artworkUrlResolver is wired", async () => {
    await service.load({
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-1",
        songId: "song-1",
      },
      metadata: {
        title: "Track",
        artworkUrl: "aonsoku-media://getCoverArt?id=art-1",
      },
      autoplay: true,
    });

    expect(engine.load).toHaveBeenLastCalledWith(
      expect.objectContaining({
        metadata: {
          title: "Track",
          artworkUrl: "aonsoku-media://getCoverArt?id=art-1",
        },
      }),
    );
  });

  it("drops artwork when the artworkUrlResolver throws", async () => {
    const resolvingEngine = new FakeAudioEngine();
    const resolvingService = new NativeAudioService({
      engine: resolvingEngine,
      audioCacheDirectory,
      cacheLoadedStreams: false,
      artworkUrlResolver: () => {
        throw new Error("missing_credentials");
      },
    });

    try {
      await resolvingService.load({
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=song-1",
          songId: "song-1",
        },
        metadata: { title: "Track", artworkUrl: "mf-1234" },
        autoplay: true,
      });

      expect(resolvingEngine.load).toHaveBeenLastCalledWith(
        expect.objectContaining({
          metadata: { title: "Track", artworkUrl: undefined },
        }),
      );
    } finally {
      resolvingService.destroy();
    }
  });

  it("loads cached stream sources as native-file targets from the audio cache", async () => {
    const songId = "song/cache-stream";
    const cacheId = audioCacheId(songId);
    const data = Buffer.from("cached stream audio");

    const stored = await service.storeAudioFile({
      songId,
      dataBase64: data.toString("base64"),
      contentType: "audio/mpeg",
    });
    const expectedAudioPath = path.join(audioCacheDirectory, `${cacheId}.mp3`);
    expect(fileURLToPath(stored.uri)).toBe(expectedAudioPath);

    await service.load({
      requestId: "request-cached-stream",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-cache-stream",
        songId,
      },
      metadata: { title: "Cached Stream", duration: 99 },
      autoplay: true,
      startTime: 5,
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "native-file",
        target: expectedAudioPath,
      },
      metadata: { title: "Cached Stream", duration: 99 },
      autoplay: true,
      startTime: 5,
    });
  });

  it("falls back to the stream URL when the cached audio file is missing", async () => {
    await service.load({
      requestId: "request-uncached-stream",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-missing-cache",
        songId: "song-missing-cache",
      },
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-missing-cache",
      },
      metadata: undefined,
      autoplay: undefined,
      startTime: undefined,
    });
  });

  it("loads stream sources without a songId through the stream URL", async () => {
    await service.load({
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-no-id",
      },
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-no-id",
      },
      metadata: undefined,
      autoplay: undefined,
      startTime: undefined,
    });
  });

  it("preserves native-file source semantics regardless of cache state", async () => {
    const songId = "song/native-file-cache";
    const cacheId = audioCacheId(songId);
    await service.storeAudioFile({
      songId,
      dataBase64: Buffer.from("unused cache").toString("base64"),
      contentType: "audio/mpeg",
    });
    const cachedPath = path.join(audioCacheDirectory, `${cacheId}.mp3`);

    await service.load({
      source: {
        kind: "native-file",
        uri: pathToFileURL("/tmp/explicit-native.mp3").toString(),
        songId,
      },
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "native-file",
        target: "/tmp/explicit-native.mp3",
      },
      metadata: undefined,
      autoplay: undefined,
      startTime: undefined,
    });
    // The cached stream copy must not be used when an explicit native-file
    // uri is provided.
    expect(engine.load).not.toHaveBeenCalledWith(
      expect.objectContaining({
        source: { kind: "native-file", target: cachedPath },
      }),
    );
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

  it("preserves coded engine failures in error events", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));
    const error = Object.assign(new Error("libmpv addon is missing"), {
      code: "libmpv-unavailable",
    });
    engine.load.mockRejectedValueOnce(error);

    await expect(
      service.load({
        requestId: "request-libmpv",
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=song-1",
        },
      }),
    ).rejects.toThrow("libmpv addon is missing");

    expect(events).toEqual([
      {
        eventName: "playbackStateChanged",
        event: {
          requestId: "request-libmpv",
          state: "failed",
        },
      },
      {
        eventName: "error",
        event: {
          requestId: "request-libmpv",
          code: "libmpv-unavailable",
          message: "libmpv addon is missing",
        },
      },
    ]);
  });

  it("replays startup libmpv availability failures to new listeners", async () => {
    service.destroy();
    const startupEngine = new FakeAudioEngine();
    startupEngine.getDiagnostics = () => ({
      backend: "libmpv",
      status: "unavailable",
      code: "libmpv-addon-unavailable",
      message: "Unable to load the Aonsoku libmpv native addon.",
      platformKey: "darwin-arm64",
      searchedPaths: ["/missing/aonsoku_libmpv.node"],
    });
    const startupService = new NativeAudioService({
      engine: startupEngine,
      audioCacheDirectory,
    });
    const events: unknown[] = [];

    try {
      startupService.onEvent((event) => events.push(event));
      await delay(0);

      expect(events).toEqual([
        {
          eventName: "error",
          event: {
            code: "libmpv-addon-unavailable",
            message: "Unable to load the Aonsoku libmpv native addon.",
          },
        },
      ]);
    } finally {
      startupService.destroy();
    }
  });

  it("emits startup check failures that happen after listeners attach", async () => {
    service.destroy();
    const startupEngine = new FakeAudioEngine();
    startupEngine.checkAvailability = vi.fn(async () => {
      throw Object.assign(new Error("libmpv property observer failed"), {
        code: "mpv-observer-failed",
      });
    });
    const startupService = new NativeAudioService({
      engine: startupEngine,
      audioCacheDirectory,
    });
    const events: unknown[] = [];

    try {
      startupService.onEvent((event) => events.push(event));
      await delay(0);

      expect(events).toEqual([
        {
          eventName: "error",
          event: {
            code: "mpv-observer-failed",
            message:
              "Desktop native audio startup check failed: libmpv property observer failed",
          },
        },
      ]);
    } finally {
      startupService.destroy();
    }
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
      deletedCount: 4,
    });
    await expect(fs.readdir(audioCacheDirectory)).resolves.toEqual([]);
  });

  it("derives the default desktop cache directory below Electron userData", () => {
    expect(
      audioCacheDirectoryFromUserDataPath(path.join("tmp", "user-data")),
    ).toBe(path.join("tmp", "user-data", "AudioCache"));
  });

  it("downloads audio files with progress and completion events", async () => {
    const songId = "song-download";
    const body = Buffer.from("downloaded audio bytes");
    const fetchMock = mockAudioFetch({
      body,
      contentType: "audio/ogg",
    });
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.load({
      requestId: "request-download",
      source: {
        kind: "stream",
        url: `https://server/rest/stream?id=${songId}`,
        songId,
      },
    });

    const completedPromise = waitForServiceEvent(
      service,
      "downloadCompleted",
      (event) => event.songId === songId,
    );

    await service.downloadAudioFile({
      songId,
      maxBitRate: 128,
      format: "opus",
    });

    const completed = await completedPromise;
    const requestedUrl = String(fetchMock.mock.calls[0]?.[0]);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(requestedUrl).toContain("id=song-download");
    expect(requestedUrl).toContain("estimateContentLength=true");
    expect(requestedUrl).toContain("maxBitRate=128");
    expect(requestedUrl).toContain("format=opus");
    expect(completed).toEqual({
      songId,
      uri: expect.stringMatching(/^file:/u),
      contentType: "audio/ogg",
      sizeBytes: body.byteLength,
    });
    expect(events).toContainEqual({
      eventName: "downloadProgress",
      event: {
        songId,
        loaded: body.byteLength,
        total: body.byteLength,
      },
    });
    await expect(service.resolveAudioFile({ songId })).resolves.toEqual({
      file: {
        songId,
        uri: completed.uri,
        contentType: "audio/ogg",
        sizeBytes: body.byteLength,
        lastModifiedAt: expect.any(Number),
      },
    });
    expect(await fs.readFile(fileURLToPath(completed.uri), "utf8")).toBe(
      "downloaded audio bytes",
    );
  });

  it("downloads audio files from the desktop URL resolver without a loaded stream", async () => {
    const songId = "song-resolved-download";
    const body = Buffer.from("resolved downloaded audio bytes");
    const fetchMock = mockAudioFetch({
      body,
      contentType: "audio/mpeg",
    });
    const resolvingService = new NativeAudioService({
      engine,
      audioCacheDirectory,
      cacheLoadedStreams: false,
      downloadUrlResolver: ({ songId, maxBitRate, format }) => {
        const url = new URL("https://server/rest/stream.view");
        url.searchParams.set("id", songId);
        if (maxBitRate !== undefined) {
          url.searchParams.set("maxBitRate", maxBitRate.toString());
        }
        if (format) {
          url.searchParams.set("format", format);
        }
        return url.toString();
      },
    });

    try {
      const completedPromise = waitForServiceEvent(
        resolvingService,
        "downloadCompleted",
        (event) => event.songId === songId,
      );

      await resolvingService.downloadAudioFile({
        songId,
        maxBitRate: 192,
        format: "mp3",
      });

      const completed = await completedPromise;
      const requestedUrl = String(fetchMock.mock.calls[0]?.[0]);

      expect(requestedUrl).toContain("id=song-resolved-download");
      expect(requestedUrl).toContain("estimateContentLength=true");
      expect(requestedUrl).toContain("maxBitRate=192");
      expect(requestedUrl).toContain("format=mp3");
      await expect(
        resolvingService.resolveAudioFile({ songId }),
      ).resolves.toEqual({
        file: {
          songId,
          uri: completed.uri,
          contentType: "audio/mpeg",
          sizeBytes: body.byteLength,
          lastModifiedAt: expect.any(Number),
        },
      });
    } finally {
      resolvingService.destroy();
    }
  });

  it("emits downloadFailed when a desktop audio download fails", async () => {
    const songId = "song-failed";
    mockAudioFetch({
      statusCode: 500,
      body: Buffer.from("server failed"),
    });

    await service.load({
      source: {
        kind: "stream",
        url: `https://server/rest/stream?id=${songId}`,
        songId,
      },
    });

    const failedPromise = waitForServiceEvent(
      service,
      "downloadFailed",
      (event) => event.songId === songId,
    );

    await service.downloadAudioFile({ songId });

    await expect(failedPromise).resolves.toEqual({
      songId,
      error: "HTTP 500",
    });
    await expect(service.resolveAudioFile({ songId })).resolves.toEqual({
      file: null,
    });
  });

  it("cancels active audio downloads without completing or failing them", async () => {
    const songId = "song-cancel";
    mockSlowAudioFetch({
      body: Buffer.from("slow downloaded audio bytes"),
      contentType: "audio/mpeg",
      chunkDelayMs: 50,
    });
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.load({
      source: {
        kind: "stream",
        url: `https://server/rest/stream?id=${songId}`,
        songId,
      },
    });

    const progressPromise = waitForServiceEvent(
      service,
      "downloadProgress",
      (event) => event.songId === songId,
    );

    await service.downloadAudioFile({ songId });
    await progressPromise;
    await service.cancelDownload({ songId });
    await delay(150);

    expect(events).not.toContainEqual(
      expect.objectContaining({ eventName: "downloadCompleted" }),
    );
    expect(events).not.toContainEqual(
      expect.objectContaining({ eventName: "downloadFailed" }),
    );
    await expect(service.resolveAudioFile({ songId })).resolves.toEqual({
      file: null,
    });
  });

  it("emits streamCacheCompleted for the default loaded stream cache path", async () => {
    const songId = "song-background-cache";
    const body = Buffer.from("background cached audio");
    mockAudioFetch({
      body,
      contentType: "audio/flac",
    });
    const backgroundService = new NativeAudioService({
      engine,
      audioCacheDirectory,
    });
    const events: unknown[] = [];
    backgroundService.onEvent((event) => events.push(event));

    try {
      const completedPromise = waitForServiceEvent(
        backgroundService,
        "streamCacheCompleted",
        (event) => event.songId === songId,
      );

      await backgroundService.load({
        source: {
          kind: "stream",
          url: `https://server/rest/stream?id=${songId}`,
          songId,
        },
      });

      const completed = await completedPromise;

      expect(completed).toEqual({
        songId,
        uri: expect.stringMatching(/^file:/u),
        contentType: "audio/flac",
        sizeBytes: body.byteLength,
      });
      expect(events).not.toContainEqual(
        expect.objectContaining({ eventName: "downloadProgress" }),
      );
      await expect(
        backgroundService.resolveAudioFile({ songId }),
      ).resolves.toEqual({
        file: {
          songId,
          uri: completed.uri,
          contentType: "audio/flac",
          sizeBytes: body.byteLength,
          lastModifiedAt: expect.any(Number),
        },
      });
    } finally {
      backgroundService.destroy();
    }
  });

  it("does not fetch or emit streamCacheCompleted when the loaded stream is already cached", async () => {
    const songId = "song-already-cached";
    const cachedBytes = Buffer.from("already cached audio");
    await service.storeAudioFile({
      songId,
      dataBase64: cachedBytes.toString("base64"),
      contentType: "audio/mpeg",
    });
    const fetchMock = mockAudioFetch({
      body: Buffer.from("should not be downloaded"),
      contentType: "audio/mpeg",
    });

    const backgroundService = new NativeAudioService({
      engine,
      audioCacheDirectory,
    });
    const events: unknown[] = [];
    backgroundService.onEvent((event) => events.push(event));

    try {
      await backgroundService.load({
        source: {
          kind: "stream",
          url: `https://server/rest/stream?id=${songId}`,
          songId,
        },
      });
      // Give the skipIfCached background cache path time to run.
      await delay(50);

      expect(fetchMock).not.toHaveBeenCalled();
      expect(events).not.toContainEqual(
        expect.objectContaining({ eventName: "streamCacheCompleted" }),
      );
      await expect(
        backgroundService.resolveAudioFile({ songId }),
      ).resolves.toEqual({
        file: expect.objectContaining({
          songId,
          contentType: "audio/mpeg",
          sizeBytes: cachedBytes.byteLength,
        }),
      });
    } finally {
      backgroundService.destroy();
    }
  });

  it("does not start a second fetch when the same songId is downloaded twice", async () => {
    const songId = "song-duplicate-download";
    const fetchMock = mockSlowAudioFetch({
      body: Buffer.from("slow downloaded audio bytes"),
      contentType: "audio/mpeg",
      chunkDelayMs: 50,
    });

    await service.load({
      source: {
        kind: "stream",
        url: `https://server/rest/stream?id=${songId}`,
        songId,
      },
    });

    const completedPromise = waitForServiceEvent(
      service,
      "downloadCompleted",
      (event) => event.songId === songId,
    );

    await Promise.all([
      service.downloadAudioFile({ songId }),
      service.downloadAudioFile({ songId }),
    ]);

    await completedPromise;

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("cancelAll cancels multiple active downloads without leaving cache files", async () => {
    const songIds = [
      "song-cancelall-1",
      "song-cancelall-2",
      "song-cancelall-3",
    ];
    mockSlowAudioFetch({
      body: Buffer.from("slow downloaded audio bytes"),
      contentType: "audio/mpeg",
      chunkDelayMs: 100,
    });

    const resolverService = new NativeAudioService({
      engine,
      audioCacheDirectory,
      downloadUrlResolver: ({ songId }) =>
        `https://server/rest/stream?id=${songId}`,
    });
    const events: unknown[] = [];
    resolverService.onEvent((event) => events.push(event));

    try {
      const before = await listAonsokuTempDirs();
      const progressPromises = songIds.map((songId) =>
        waitForServiceEvent(
          resolverService,
          "downloadProgress",
          (event) => event.songId === songId,
        ),
      );

      await Promise.all(
        songIds.map((songId) => resolverService.downloadAudioFile({ songId })),
      );
      await Promise.all(progressPromises);

      await resolverService.cancelDownload();
      await delay(200);

      expect(events).not.toContainEqual(
        expect.objectContaining({ eventName: "downloadCompleted" }),
      );
      expect(events).not.toContainEqual(
        expect.objectContaining({ eventName: "downloadFailed" }),
      );
      for (const songId of songIds) {
        await expect(
          resolverService.resolveAudioFile({ songId }),
        ).resolves.toEqual({ file: null });
      }
      const after = await listAonsokuTempDirs();
      expect(after.filter((dir) => !before.includes(dir))).toEqual([]);
    } finally {
      resolverService.destroy();
    }
  });

  it("cleans up the temp directory when a download fails mid-stream", async () => {
    const songId = "song-midstream-fail";
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new Uint8Array(Buffer.from("partial bytes")));
            controller.error(new Error("stream broke mid-download"));
          },
        }),
        {
          status: 200,
          headers: {
            "content-type": "audio/mpeg",
            "content-length": "100",
          },
        },
      ),
    );

    const before = await listAonsokuTempDirs();

    await service.load({
      source: {
        kind: "stream",
        url: `https://server/rest/stream?id=${songId}`,
        songId,
      },
    });

    const failedPromise = waitForServiceEvent(
      service,
      "downloadFailed",
      (event) => event.songId === songId,
    );

    await service.downloadAudioFile({ songId });

    await expect(failedPromise).resolves.toEqual({
      songId,
      error: "stream broke mid-download",
    });
    await delay(20);

    const after = await listAonsokuTempDirs();
    expect(after.filter((dir) => !before.includes(dir))).toEqual([]);
    await expect(service.resolveAudioFile({ songId })).resolves.toEqual({
      file: null,
    });
    fetchMock.mockRestore();
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

    await vi.waitFor(() => expect(events).toHaveLength(7));

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
        eventName: "playbackStateChanged",
        event: {
          requestId: "request-1",
          state: "failed",
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

  it("settles playing engine errors once and recovers on successful playback", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    service.destroy();
    const playbackStateStore = {
      load: vi.fn(() => null),
      save: vi.fn(),
      clear: vi.fn(),
    } as unknown as DesktopPlaybackStateStore;
    service = new NativeAudioService({
      engine,
      audioCacheDirectory,
      cacheLoadedStreams: false,
      playbackStateStore,
    });
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    try {
      await service.load({
        requestId: "request-failing-playback",
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=failing-playback",
          songId: "failing-playback",
        },
        autoplay: true,
      });
      engine.emit({ type: "playbackStateChanged", state: "playing" });
      engine.emit({ type: "bufferingChanged", isBuffering: true });
      vi.advanceTimersByTime(1_000);

      const failed = waitForServiceEvent(
        service,
        "playbackStateChanged",
        (event) => event.state === "failed",
      );
      engine.emit({
        type: "error",
        code: "mpv-playback-error",
        message: "decoder failed",
      });
      engine.emit({
        type: "error",
        code: "mpv-playback-error",
        message: "decoder failed",
      });
      await failed;
      await vi.advanceTimersByTimeAsync(500);

      expect(service.getDebugExtras().isBuffering).toBe(false);
      expect(service.getControlState().isPlaying).toBe(false);
      expect(playbackStateStore.save).toHaveBeenLastCalledWith(
        expect.objectContaining({ isPlaying: false }),
      );
      expect(
        events.filter(
          (event) =>
            (event as { eventName?: string }).eventName ===
              "playbackStateChanged" &&
            (event as { event?: { state?: string } }).event?.state === "failed",
        ),
      ).toHaveLength(1);
      expect(
        events.filter(
          (event) => (event as { eventName?: string }).eventName === "error",
        ),
      ).toHaveLength(1);
      expect(events).toContainEqual({
        eventName: "bufferingChanged",
        event: {
          requestId: "request-failing-playback",
          isBuffering: false,
        },
      });

      vi.advanceTimersByTime(1_000);
      engine.play.mockImplementationOnce(async () => {
        engine.emit({ type: "playbackStateChanged", state: "playing" });
      });
      await service.play();
      expect(service.getControlState().isPlaying).toBe(true);
      vi.advanceTimersByTime(500);

      await service.load({
        requestId: "request-recovery-load",
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=recovery-load",
          songId: "recovery-load",
        },
      });
      await expect(service.getScrobbleBuffer()).resolves.toEqual({
        entries: [
          {
            songId: "failing-playback",
            playedDurationMs: 1_500,
            timestamp: 1_000,
          },
        ],
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("settles loading errors without duplicating a rejected load failure", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));
    engine.loadImplementation = async () => {
      engine.emit({ type: "playbackStateChanged", state: "loading" });
      engine.emit({ type: "bufferingChanged", isBuffering: true });
      engine.emit({
        type: "error",
        code: "mpv-playback-error",
        message: "demuxer failed",
      });
      throw Object.assign(new Error("demuxer failed"), {
        code: "mpv-playback-error",
      });
    };

    await expect(
      service.load({
        requestId: "request-failing-load",
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=failing-load",
        },
      }),
    ).rejects.toThrow("demuxer failed");
    await delay(0);

    expect(service.getDebugExtras().isBuffering).toBe(false);
    expect(
      events.filter(
        (event) =>
          (event as { eventName?: string }).eventName ===
            "playbackStateChanged" &&
          (event as { event?: { state?: string } }).event?.state === "failed",
      ),
    ).toHaveLength(1);
    expect(
      events.filter(
        (event) => (event as { eventName?: string }).eventName === "error",
      ),
    ).toHaveLength(1);

    engine.loadImplementation = async () => {
      engine.emit({ type: "playbackStateChanged", state: "paused" });
    };
    await service.load({
      requestId: "request-recovered-load",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=recovered-load",
      },
    });
    engine.play.mockImplementationOnce(async () => {
      engine.emit({ type: "playbackStateChanged", state: "playing" });
    });
    await service.play();
    expect(service.getControlState().isPlaying).toBe(true);
  });

  it("ignores an old engine error queued behind a newer load", async () => {
    await service.load({
      requestId: "request-old",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=old",
      },
    });
    const pendingPlay = deferred<void>();
    engine.play.mockImplementationOnce(() => pendingPlay.promise);
    const play = service.play();
    const nextLoad = service.load({
      requestId: "request-new",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=new",
      },
    });
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    engine.emit({
      type: "error",
      code: "mpv-playback-error",
      message: "late old-source error",
    });
    pendingPlay.resolve();
    await Promise.all([play, nextLoad]);
    await delay(0);

    expect(
      events.filter(
        (event) =>
          (event as { eventName?: string }).eventName === "error" ||
          (event as { event?: { state?: string } }).event?.state === "failed",
      ),
    ).toEqual([]);
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

  it("routes desktop volume to the player and HUD/like through the system adapter", async () => {
    const systemAudioAdapter = createFakeSystemAudioAdapter();
    const systemService = new NativeAudioService({
      engine,
      audioCacheDirectory,
      systemAudioAdapter,
    });
    const events: unknown[] = [];
    systemService.onEvent((event) => events.push(event));

    try {
      await expect(
        systemService.setSystemVolume({ value: 1.5 }),
      ).resolves.toEqual({
        volume: 1,
      });
      await expect(systemService.getSystemVolume()).resolves.toEqual({
        volume: 1,
      });
      await systemService.setVolumeHUDEnabled({ enabled: false });
      await systemService.setLikeActive({ active: true });

      expect(engine.setVolume).toHaveBeenCalledWith(1);
      expect(systemAudioAdapter.setVolumeHUDEnabled).toHaveBeenCalledWith(
        false,
      );
      expect(systemAudioAdapter.setLikeActive).toHaveBeenCalledWith(true);
      expect(events).toContainEqual({
        eventName: "systemVolumeChanged",
        event: {
          volume: 1,
        },
      });
    } finally {
      systemService.destroy();
    }
  });

  it("routes media commands to remote-control events while projecting remote playback", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.updateRemotePlaybackState({
      metadata: {
        title: "Remote song",
        artist: "Remote artist",
        duration: 180,
      },
      isPlaying: true,
      position: 12,
      duration: 180,
      isShuffleActive: true,
      repeatMode: "all",
      volume: 0.5,
      targetDeviceId: "device-target",
      expectedGeneration: 7,
    });

    await expect(service.handleRemoteCommand("play")).resolves.toBe(true);
    service.emitRemoteCommand("shuffle");
    service.emitRemoteCommand("seek", { position: -4 });

    expect(engine.play).not.toHaveBeenCalled();
    expect(events).toContainEqual({
      eventName: "remoteControlCommand",
      event: {
        requestId: undefined,
        targetDeviceId: "device-target",
        expectedGeneration: 7,
        handledNatively: false,
        command: { type: "play" },
      },
    });
    expect(events).toContainEqual({
      eventName: "remoteControlCommand",
      event: {
        requestId: undefined,
        targetDeviceId: "device-target",
        expectedGeneration: 7,
        handledNatively: false,
        command: { type: "set_shuffle", enabled: false },
      },
    });
    expect(events).toContainEqual({
      eventName: "remoteControlCommand",
      event: {
        requestId: undefined,
        targetDeviceId: "device-target",
        expectedGeneration: 7,
        handledNatively: false,
        command: { type: "seek", seconds: 0 },
      },
    });

    events.length = 0;
    await service.clearRemotePlaybackState();
    service.emitRemoteCommand("next");

    expect(events).toContainEqual({
      eventName: "remoteCommand",
      event: {
        requestId: undefined,
        command: "next",
      },
    });
  });

  it("applies system media commands to local playback", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.load({
      requestId: "request-system-command",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-1",
        songId: "song-1",
      },
      metadata: { title: "Track", duration: 100 },
      autoplay: true,
    });
    engine.emit({ type: "playbackStateChanged", state: "playing" });
    engine.play.mockClear();
    engine.pause.mockClear();
    engine.seek.mockClear();
    events.length = 0;

    // togglePlayPause while playing pauses locally instead of round-tripping
    // through the renderer.
    engine.emit({ type: "systemMediaCommand", command: "togglePlayPause" });
    await vi.waitFor(() => expect(engine.pause).toHaveBeenCalled());

    // A seek from the system scrubber drives the engine directly.
    engine.emit({ type: "systemMediaCommand", command: "seek", position: 33 });
    await vi.waitFor(() => expect(engine.seek).toHaveBeenLastCalledWith(33));

    // Neither command is forwarded as a renderer remoteCommand anymore.
    expect(events).not.toContainEqual(
      expect.objectContaining({ eventName: "remoteCommand" }),
    );
  });

  it("forwards like/shuffle system media commands to the renderer", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.load({
      requestId: "request-system-command",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-1",
        songId: "song-1",
      },
      metadata: { title: "Track", duration: 100 },
      autoplay: true,
    });
    events.length = 0;

    engine.emit({ type: "systemMediaCommand", command: "like" });
    engine.emit({ type: "systemMediaCommand", command: "shuffle" });

    await vi.waitFor(() => expect(events).toHaveLength(2));

    expect(events).toContainEqual({
      eventName: "remoteCommand",
      event: {
        requestId: "request-system-command",
        command: "like",
      },
    });
    expect(events).toContainEqual({
      eventName: "remoteCommand",
      event: {
        requestId: "request-system-command",
        command: "shuffle",
      },
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

  it("serializes consecutive next commands before mutating queue state", async () => {
    await service.setContextQueue({
      songs: [queueSong("1"), queueSong("2"), queueSong("3")],
      currentIndex: 0,
    });
    const pendingLoads: Deferred<void>[] = [];
    engine.loadImplementation = () => {
      const pending = deferred<void>();
      pendingLoads.push(pending);
      return pending.promise;
    };
    engine.load.mockClear();

    const first = service.skipToNext();
    const second = service.skipToNext();

    await vi.waitFor(() => expect(pendingLoads).toHaveLength(1));
    expect(engine.load).toHaveBeenCalledTimes(1);
    pendingLoads[0]?.resolve();
    await vi.waitFor(() => expect(pendingLoads).toHaveLength(2));
    expect(engine.load).toHaveBeenCalledTimes(2);
    pendingLoads[1]?.resolve();
    await Promise.all([first, second]);

    expect(
      engine.load.mock.calls.map(([options]) => options.metadata?.title),
    ).toEqual(["Title 2", "Title 3"]);
    await expect(service.getFullState()).resolves.toMatchObject({
      contextQueue: { currentIndex: 2 },
      currentSongId: "3",
    });
  });

  it("orders system media and renderer queue commands through one FIFO", async () => {
    await service.setContextQueue({
      songs: [queueSong("1"), queueSong("2"), queueSong("3")],
      currentIndex: 0,
    });
    const pendingLoads: Deferred<void>[] = [];
    engine.loadImplementation = () => {
      const pending = deferred<void>();
      pendingLoads.push(pending);
      return pending.promise;
    };
    engine.load.mockClear();

    const rendererNext = service.skipToNext();
    engine.emit({ type: "systemMediaCommand", command: "previous" });
    const rendererNextAgain = service.skipToNext();

    for (let index = 0; index < 3; index += 1) {
      await vi.waitFor(() => expect(pendingLoads.length).toBe(index + 1));
      pendingLoads[index]?.resolve();
    }
    await Promise.all([rendererNext, rendererNextAgain]);

    expect(
      engine.load.mock.calls.map(([options]) => options.metadata?.title),
    ).toEqual(["Title 2", "Title 1", "Title 2"]);
    await expect(service.getFullState()).resolves.toMatchObject({
      contextQueue: { currentIndex: 1 },
      currentSongId: "2",
    });
  });

  it("rolls back a failed queue load and continues later commands", async () => {
    service.destroy();
    const playbackStateStore = {
      load: vi.fn(() => null),
      save: vi.fn(),
      clear: vi.fn(),
    } as unknown as DesktopPlaybackStateStore;
    service = new NativeAudioService({
      engine,
      audioCacheDirectory,
      cacheLoadedStreams: false,
      playbackStateStore,
    });
    const events: Array<{ eventName: string; event: unknown }> = [];
    service.onEvent((event) => events.push(event));
    await service.setContextQueue({
      songs: [queueSong("1"), queueSong("2"), queueSong("3")],
      currentIndex: 0,
    });
    events.length = 0;
    const pendingLoads: Deferred<void>[] = [];
    engine.loadImplementation = () => {
      const pending = deferred<void>();
      pendingLoads.push(pending);
      return pending.promise;
    };

    const failed = service.skipToNext();
    const subsequent = service.skipToNext();
    await vi.waitFor(() => expect(pendingLoads).toHaveLength(1));
    pendingLoads[0]?.reject(new Error("delayed load failed"));
    await expect(failed).rejects.toThrow("delayed load failed");
    expect(playbackStateStore.save).toHaveBeenLastCalledWith(
      expect.objectContaining({
        contextQueue: expect.objectContaining({ currentIndex: 0 }),
        currentSongId: "1",
      }),
    );

    await vi.waitFor(() => expect(pendingLoads).toHaveLength(2));
    expect(engine.load.mock.calls.at(-1)?.[0].metadata?.title).toBe("Title 2");
    pendingLoads[1]?.resolve();
    await subsequent;

    await expect(service.getFullState()).resolves.toMatchObject({
      contextQueue: { currentIndex: 1 },
      currentSongId: "2",
    });
    await service.destroy();
    expect(playbackStateStore.save).toHaveBeenLastCalledWith(
      expect.objectContaining({
        contextQueue: expect.objectContaining({ currentIndex: 1 }),
        currentSongId: "2",
      }),
    );
    expect(
      events.filter((event) => event.eventName === "queueStateChanged"),
    ).toEqual([
      {
        eventName: "queueStateChanged",
        event: expect.objectContaining({
          currentIndex: 1,
          songId: "2",
          reason: "next",
        }),
      },
    ]);
    expect(
      events.filter((event) => event.eventName === "queueContentsChanged"),
    ).toEqual([]);
  });

  it("loads a queued song from the audio cache when cachedFileUri is absent", async () => {
    const songId = "song/queue-cache";
    const cacheId = audioCacheId(songId);
    const data = Buffer.from("queued cached audio");
    await service.storeAudioFile({
      songId,
      dataBase64: data.toString("base64"),
      contentType: "audio/mpeg",
    });
    const expectedAudioPath = path.join(audioCacheDirectory, `${cacheId}.mp3`);

    await service.setContextQueue({
      songs: [
        {
          id: songId,
          title: "Queued Cached",
          artist: "Artist",
          album: "Album",
          duration: 80,
          streamUrl: `https://server/rest/stream?id=${songId}`,
        },
      ],
      currentIndex: 0,
      autoplay: true,
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "native-file",
        target: expectedAudioPath,
      },
      metadata: {
        title: "Queued Cached",
        artist: "Artist",
        album: "Album",
        duration: 80,
        artworkUrl: undefined,
      },
      autoplay: true,
      startTime: undefined,
    });
  });

  it("falls back to the stream URL for a queued song missing from the cache", async () => {
    await service.setContextQueue({
      songs: [
        {
          id: "song-queue-miss",
          title: "Queued Miss",
          artist: "Artist",
          album: "Album",
          duration: 70,
          streamUrl: "https://server/rest/stream?id=song-queue-miss",
        },
      ],
      currentIndex: 0,
      autoplay: false,
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=song-queue-miss",
      },
      metadata: {
        title: "Queued Miss",
        artist: "Artist",
        album: "Album",
        duration: 70,
        artworkUrl: undefined,
      },
      autoplay: false,
      startTime: undefined,
    });
  });

  it("prefers an explicit cachedFileUri on a queued song over the audio cache", async () => {
    const songId = "song/queue-explicit";
    const cacheId = audioCacheId(songId);
    await service.storeAudioFile({
      songId,
      dataBase64: Buffer.from("cache copy that should be ignored").toString(
        "base64",
      ),
      contentType: "audio/mpeg",
    });
    const cachedPath = path.join(audioCacheDirectory, `${cacheId}.mp3`);
    const explicitUri = pathToFileURL("/tmp/explicit-queue.mp3").toString();

    await service.setContextQueue({
      songs: [
        {
          id: songId,
          title: "Queued Explicit",
          artist: "Artist",
          album: "Album",
          duration: 60,
          streamUrl: `https://server/rest/stream?id=${songId}`,
          cachedFileUri: explicitUri,
        },
      ],
      currentIndex: 0,
      autoplay: true,
    });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "native-file",
        target: "/tmp/explicit-queue.mp3",
      },
      metadata: {
        title: "Queued Explicit",
        artist: "Artist",
        album: "Album",
        duration: 60,
        artworkUrl: undefined,
      },
      autoplay: true,
      startTime: undefined,
    });
    expect(engine.load).not.toHaveBeenCalledWith(
      expect.objectContaining({
        source: { kind: "native-file", target: cachedPath },
      }),
    );
  });

  it("resolves a cached queued song through playAtIndex", async () => {
    const songId = "song/queue-playat";
    const cacheId = audioCacheId(songId);
    await service.storeAudioFile({
      songId,
      dataBase64: Buffer.from("playAtIndex cached audio").toString("base64"),
      contentType: "audio/mpeg",
    });
    const expectedAudioPath = path.join(audioCacheDirectory, `${cacheId}.mp3`);

    await service.setContextQueue({
      songs: [
        {
          id: "song/queue-other",
          title: "Other",
          artist: "Artist",
          album: "Album",
          duration: 50,
          streamUrl: "https://server/rest/stream?id=song/queue-other",
        },
        {
          id: songId,
          title: "PlayAtIndex Cached",
          artist: "Artist",
          album: "Album",
          duration: 90,
          streamUrl: `https://server/rest/stream?id=${songId}`,
        },
      ],
      currentIndex: 0,
      autoplay: false,
    });
    engine.load.mockClear();

    await service.playAtIndex({ index: 1, startTime: 7 });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "native-file",
        target: expectedAudioPath,
      },
      metadata: {
        title: "PlayAtIndex Cached",
        artist: "Artist",
        album: "Album",
        duration: 90,
        artworkUrl: undefined,
      },
      autoplay: true,
      startTime: 7,
    });
  });

  it("bridges context and user queue edits through full native state", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.setContextQueue({
      songs: [queueSong("1"), queueSong("2"), queueSong("3")],
      currentIndex: 0,
      sourceId: { type: "playlist", id: "playlist-1" },
      sourceName: "Playlist One",
      repeatMode: "all",
    });
    await service.addToUserQueue({
      songs: [queueSong("A"), queueSong("B")],
      position: "next",
    });

    await service.skipToNext();
    await service.skipToNext();
    await service.skipToNext();
    await service.playAtIndex({ index: 2, startTime: 9 });

    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=3",
      },
      metadata: {
        title: "Title 3",
        artist: "Artist",
        album: "Album",
        duration: 100,
        artworkUrl: "cover-3",
      },
      autoplay: true,
      startTime: 9,
    });
    await expect(service.getFullState()).resolves.toMatchObject({
      contextQueue: {
        currentIndex: 2,
        sourceId: { type: "playlist", id: "playlist-1" },
        sourceName: "Playlist One",
      },
      userQueue: [],
      playedUserQueueHistory: [
        expect.objectContaining({ id: "A" }),
        expect.objectContaining({ id: "B" }),
      ],
      isInUserQueue: false,
      isShuffleActive: false,
      loopState: "all",
      currentSongId: "3",
    });
    expect(events).toContainEqual({
      eventName: "queueStateChanged",
      event: {
        requestId: "desktop-native-queue-5",
        currentIndex: 2,
        songId: "3",
        reason: "skip",
        isInUserQueue: false,
      },
    });
    expect(events).toContainEqual({
      eventName: "queueContentsChanged",
      event: {
        requestId: "desktop-native-queue-1",
        reason: "queue-edit",
      },
    });
  });

  it("bridges queue reordering, user queue removal, and shuffle events", async () => {
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    await service.setContextQueue({
      songs: [queueSong("1"), queueSong("2"), queueSong("3")],
      currentIndex: 0,
    });
    await service.reorderContextQueue({ fromIndex: 0, toIndex: 2 });
    await service.addToUserQueue({
      songs: [queueSong("A"), queueSong("B")],
      position: "last",
    });
    await service.removeFromUserQueue({ indices: [0] });
    await service.setShuffle({ enabled: true });
    await service.setShuffle({ enabled: false });
    await service.clearUserQueue();

    await expect(service.getFullState()).resolves.toMatchObject({
      contextQueue: {
        songs: [
          expect.objectContaining({ id: "2" }),
          expect.objectContaining({ id: "3" }),
          expect.objectContaining({ id: "1" }),
        ],
      },
      userQueue: [],
      isShuffleActive: false,
      shuffleHistory: [],
    });
    expect(events).toContainEqual({
      eventName: "queueContentsChanged",
      event: {
        requestId: "desktop-native-queue-1",
        reason: "shuffle",
      },
    });
    expect(events).toContainEqual({
      eventName: "queueContentsChanged",
      event: {
        requestId: "desktop-native-queue-1",
        reason: "unshuffle",
      },
    });
  });

  it("uses the queue engine for ended, repeat all, and repeat one", async () => {
    await service.setContextQueue({
      songs: [queueSong("1"), queueSong("2")],
      currentIndex: 1,
    });
    await service.setRepeatMode({ mode: "all" });

    const wrappedPromise = waitForServiceEvent(
      service,
      "queueStateChanged",
      (event) => event.reason === "ended" && event.songId === "1",
    );

    engine.emit({ type: "ended", reason: "finished" });

    await expect(wrappedPromise).resolves.toEqual({
      requestId: "desktop-native-queue-2",
      currentIndex: 0,
      songId: "1",
      reason: "ended",
      isInUserQueue: false,
    });
    expect(engine.load).toHaveBeenLastCalledWith({
      source: {
        kind: "stream",
        target: "https://server/rest/stream?id=1",
      },
      metadata: {
        title: "Title 1",
        artist: "Artist",
        album: "Album",
        duration: 100,
        artworkUrl: "cover-1",
      },
      autoplay: true,
      startTime: undefined,
    });

    await service.setRepeatMode({ mode: "one" });
    engine.emit({ type: "ended", reason: "finished" });
    await delay(0);

    expect(engine.seek).toHaveBeenLastCalledWith(0);
    expect(engine.play).toHaveBeenCalledTimes(1);

    await service.setRepeatMode({ mode: "off" });
    await service.playAtIndex({ index: 1 });

    const endedPromise = waitForServiceEvent(service, "ended");
    engine.emit({ type: "ended", reason: "finished" });

    await expect(endedPromise).resolves.toEqual({
      requestId: "desktop-native-queue-3",
      reason: "finished",
    });
    expect(engine.pause).toHaveBeenCalledTimes(1);
    expect(engine.seek).toHaveBeenLastCalledWith(0);
  });

  it("buffers scrobble durations across pause, resume, song switch, and ended", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);

    try {
      await service.load({
        requestId: "request-song-1",
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=song-1",
          songId: "song-1",
        },
        metadata: {
          title: "Song 1",
          duration: 100,
        },
        autoplay: true,
      });

      vi.advanceTimersByTime(1_500);
      await service.pause();
      vi.advanceTimersByTime(1_000);
      await service.play();
      vi.advanceTimersByTime(500);

      await service.load({
        requestId: "request-song-2",
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=song-2",
          songId: "song-2",
        },
        metadata: {
          title: "Song 2",
          duration: 120,
        },
        autoplay: true,
      });

      await expect(service.getScrobbleBuffer()).resolves.toEqual({
        entries: [
          {
            songId: "song-1",
            playedDurationMs: 2_000,
            timestamp: 1_000,
          },
        ],
      });

      vi.advanceTimersByTime(750);
      const endedPromise = waitForServiceEvent(service, "ended");
      engine.emit({ type: "ended", reason: "finished" });
      await endedPromise;

      await expect(service.getScrobbleBuffer()).resolves.toEqual({
        entries: [
          {
            songId: "song-1",
            playedDurationMs: 2_000,
            timestamp: 1_000,
          },
          {
            songId: "song-2",
            playedDurationMs: 750,
            timestamp: 4_000,
          },
        ],
      });

      await service.clearScrobbleBuffer();

      await expect(service.getScrobbleBuffer()).resolves.toEqual({
        entries: [],
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("fires and cancels duration sleep timers", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(10_000);
    const events: unknown[] = [];
    service.onEvent((event) => events.push(event));

    try {
      await service.load({
        requestId: "request-sleep",
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=song-1",
          songId: "song-1",
        },
        autoplay: true,
      });
      await service.setSleepTimer({ seconds: 5, mode: "duration" });

      await expect(service.getSleepTimerRemaining()).resolves.toEqual({
        remainingSeconds: 5,
      });

      vi.advanceTimersByTime(2_000);

      await expect(service.getSleepTimerRemaining()).resolves.toEqual({
        remainingSeconds: 3,
      });

      await vi.advanceTimersByTimeAsync(3_000);

      expect(engine.pause).toHaveBeenCalledTimes(1);
      expect(events).toContainEqual({
        eventName: "playbackStateChanged",
        event: {
          requestId: "request-sleep",
          state: "paused",
        },
      });
      expect(events).toContainEqual({
        eventName: "sleepTimerFired",
        event: {
          reason: "duration",
        },
      });
      await expect(service.getSleepTimerRemaining()).resolves.toEqual({
        remainingSeconds: 0,
      });

      await service.setSleepTimer({ seconds: 5, mode: "duration" });
      await service.cancelSleepTimer();
      await vi.advanceTimersByTimeAsync(5_000);

      expect(engine.pause).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("fires end-of-track sleep timers before queue advancement", async () => {
    await service.setContextQueue({
      songs: [queueSong("1"), queueSong("2")],
      currentIndex: 0,
    });
    await service.setSleepTimer({ seconds: 0, mode: "endOfTrack" });

    await expect(service.getSleepTimerRemaining()).resolves.toEqual({
      remainingSeconds: 0,
    });

    const firedPromise = waitForServiceEvent(service, "sleepTimerFired");
    engine.emit({ type: "ended", reason: "finished" });

    await expect(firedPromise).resolves.toEqual({
      reason: "endOfTrack",
    });
    expect(engine.pause).toHaveBeenCalledTimes(1);
    expect(engine.load).toHaveBeenCalledTimes(1);
    await expect(service.getFullState()).resolves.toMatchObject({
      contextQueue: {
        currentIndex: 0,
      },
      currentSongId: "1",
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

  it("unsubscribes from engine events when destroyed", () => {
    expect(engine.listeners.size).toBe(1);

    service.destroy();

    expect(engine.listeners.size).toBe(0);
  });
});

function mockAudioFetch(options: {
  body: Buffer;
  statusCode?: number;
  contentType?: string;
}) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(new Uint8Array(options.body), {
      status: options.statusCode ?? 200,
      headers: {
        "content-length": options.body.byteLength.toString(),
        "content-type": options.contentType ?? "audio/mpeg",
      },
    }),
  );
}

function mockSlowAudioFetch(options: {
  body: Buffer;
  contentType: string;
  chunkDelayMs: number;
}) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (_, init) => {
    const signal = init?.signal;
    const chunkSize = Math.max(1, Math.ceil(options.body.byteLength / 3));
    let timer: ReturnType<typeof setTimeout> | null = null;

    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        let offset = 0;

        const enqueueNextChunk = () => {
          if (signal?.aborted) {
            controller.error(new Error("Download cancelled."));
            return;
          }

          if (offset >= options.body.byteLength) {
            controller.close();
            return;
          }

          const nextOffset = Math.min(
            offset + chunkSize,
            options.body.byteLength,
          );
          controller.enqueue(options.body.subarray(offset, nextOffset));
          offset = nextOffset;
          timer = setTimeout(enqueueNextChunk, options.chunkDelayMs);
        };

        signal?.addEventListener("abort", () => {
          if (timer) clearTimeout(timer);
          controller.error(new Error("Download cancelled."));
        });

        enqueueNextChunk();
      },
    });

    return new Response(stream, {
      status: 200,
      headers: {
        "content-length": options.body.byteLength.toString(),
        "content-type": options.contentType,
      },
    });
  });
}

function createFakeSystemAudioAdapter(): DesktopSystemAudioAdapter & {
  setVolumeHUDEnabled: ReturnType<typeof vi.fn>;
  setLikeActive: ReturnType<typeof vi.fn>;
} {
  return {
    setVolumeHUDEnabled: vi.fn(async () => {}),
    setLikeActive: vi.fn(async () => {}),
  };
}

function waitForServiceEvent<TEvent extends keyof NativeAudioEvents>(
  service: NativeAudioService,
  eventName: TEvent,
  predicate?: (event: NativeAudioEvents[TEvent]) => boolean,
): Promise<NativeAudioEvents[TEvent]> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      unsubscribe();
      reject(new Error(`Timed out waiting for ${eventName}.`));
    }, 1_000);

    const unsubscribe = service.onEvent((payload) => {
      if (payload.eventName !== eventName) return;

      const event = payload.event as NativeAudioEvents[TEvent];
      if (predicate && !predicate(event)) return;

      clearTimeout(timeout);
      unsubscribe();
      resolve(event);
    });
  });
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T | PromiseLike<T>): void;
  reject(reason?: unknown): void;
}

function deferred<T>(): Deferred<T> {
  let resolve!: Deferred<T>["resolve"];
  let reject!: Deferred<T>["reject"];
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function listAonsokuTempDirs(): Promise<string[]> {
  return fs
    .readdir(tmpdir())
    .then((entries) =>
      entries.filter((entry) => entry.startsWith("aonsoku-audio-download-")),
    );
}

function queueSong(id: string) {
  return {
    id,
    title: `Title ${id}`,
    artist: "Artist",
    album: "Album",
    duration: 100,
    coverArtId: `cover-${id}`,
    streamUrl: `https://server/rest/stream?id=${id}`,
  };
}
