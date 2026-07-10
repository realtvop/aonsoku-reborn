import { clear as idbClear } from "idb-keyval";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { isAudioCached, useCacheIndexStore } from "@/store/cache-index.store";
import { cacheIndexStore } from "@/store/idb";
import { _resetLibraryDbForTests, libraryDb } from "@/store/library-db";
import { Priority } from "@/types/cache";

const cacheStorageMock = {
  clear: vi.fn(),
  delete: vi.fn(),
  get: vi.fn(),
  put: vi.fn(),
};

const audioCacheServiceMock = {
  cacheSong: vi.fn(() => Promise.resolve()),
  isQueued: vi.fn(() => false),
  isInFlight: vi.fn(() => false),
  cancelAll: vi.fn(),
};

const nativeCacheAdapterMock = {
  clearAudioFiles: vi.fn(() => Promise.resolve()),
  deleteAudioFile: vi.fn(() => Promise.resolve(false)),
  evictAudioFile: vi.fn(() => Promise.resolve(false)),
  getAudioFileSize: vi.fn(() => Promise.resolve(null)),
  resolveAudioFile: vi.fn(() => Promise.resolve(null)),
  storeAudioFile: vi.fn(() => Promise.reject(new Error("not available"))),
};

const nativeImageCacheAdapterMock = {
  clearCoverImages: vi.fn(() => Promise.resolve()),
  deleteCoverImage: vi.fn(() => Promise.resolve(true)),
  downloadAvatar: vi.fn(() => Promise.resolve(null)),
  downloadCoverImage: vi.fn(() => Promise.resolve(null)),
  getCoverImageSize: vi.fn(() =>
    Promise.resolve({ sizeBytes: null, coverSize: null }),
  ),
  resolveCoverImage: vi.fn(() => Promise.resolve(null)),
  storeCoverImage: vi.fn(() => Promise.resolve(null)),
};

const nativeCacheHelpersMock = {
  clearNativeAudioFilesIfAvailable: vi.fn(() => Promise.resolve()),
  evictNativeAudioFileIfAvailable: vi.fn(() => Promise.resolve(false)),
  getNativeCacheAdapter: vi.fn(() => nativeCacheAdapterMock),
};

vi.mock("./cache-storage", () => ({
  cacheStorage: cacheStorageMock,
}));

vi.mock("./audio-cache-worker-adapter", () => ({
  audioCacheService: audioCacheServiceMock,
}));

vi.mock("./native-cache-adapter", () => nativeCacheHelpersMock);

vi.mock("./native-image-cache-adapter", () => ({
  getNativeImageCacheAdapter: vi.fn(() => nativeImageCacheAdapterMock),
  isNativeImageCacheAdapterAvailable: vi.fn(() => false),
}));

vi.mock("@capacitor/core", () => ({
  Capacitor: {
    convertFileSrc: vi.fn((uri: string) => `converted:${uri}`),
    getServerUrl: vi.fn(() => "http://localhost"),
  },
}));

vi.mock("./sync-worker-adapter", () => ({
  syncService: {
    cancel: vi.fn(),
  },
}));
vi.mock("@/api/httpClient", () => ({
  getCoverArtUrl: vi.fn(() => "/cover"),
  getSongStreamUrl: vi.fn(() => "/stream"),
}));

vi.mock("@/service/subsonic", () => ({
  subsonic: {
    lyrics: {
      getStructuredLyrics: vi.fn(),
    },
  },
}));

vi.mock("@/store/cache.store", () => ({
  useCacheStore: {
    getState: () => ({
      settings: {
        assetsQuota: 0,
        lruQuota: 0,
      },
      actions: {
        updateCacheStats: vi.fn(),
      },
    }),
  },
}));

vi.mock("@/store/player.store", () => ({
  usePlayerStore: {
    getState: () => ({
      settings: {
        coverArt: {
          useAlbumCoverForSongs: false,
        },
      },
    }),
  },
}));

describe("cacheManager", () => {
  beforeEach(async () => {
    cacheStorageMock.clear.mockReset();
    cacheStorageMock.clear.mockResolvedValue(undefined);
    cacheStorageMock.delete.mockReset();
    cacheStorageMock.delete.mockResolvedValue(true);
    cacheStorageMock.get.mockReset();
    cacheStorageMock.get.mockResolvedValue(null);
    cacheStorageMock.put.mockReset();
    cacheStorageMock.put.mockResolvedValue(undefined);
    audioCacheServiceMock.cacheSong.mockReset();
    audioCacheServiceMock.cacheSong.mockResolvedValue(undefined);
    audioCacheServiceMock.cancelAll.mockReset();
    audioCacheServiceMock.isQueued.mockReset().mockReturnValue(false);
    audioCacheServiceMock.isInFlight.mockReset().mockReturnValue(false);
    nativeCacheHelpersMock.clearNativeAudioFilesIfAvailable
      .mockReset()
      .mockResolvedValue(undefined);
    nativeCacheHelpersMock.evictNativeAudioFileIfAvailable
      .mockReset()
      .mockResolvedValue(false);
    nativeImageCacheAdapterMock.clearCoverImages.mockReset();
    nativeImageCacheAdapterMock.clearCoverImages.mockResolvedValue(undefined);
    nativeImageCacheAdapterMock.deleteCoverImage.mockReset();
    nativeImageCacheAdapterMock.deleteCoverImage.mockResolvedValue(true);
    nativeImageCacheAdapterMock.downloadAvatar.mockReset();
    nativeImageCacheAdapterMock.downloadAvatar.mockResolvedValue(null);
    nativeImageCacheAdapterMock.downloadCoverImage.mockReset();
    nativeImageCacheAdapterMock.downloadCoverImage.mockResolvedValue(null);
    nativeImageCacheAdapterMock.getCoverImageSize.mockReset();
    nativeImageCacheAdapterMock.getCoverImageSize.mockResolvedValue({
      sizeBytes: null,
      coverSize: null,
    });
    nativeImageCacheAdapterMock.resolveCoverImage.mockReset();
    nativeImageCacheAdapterMock.resolveCoverImage.mockResolvedValue(null);
    nativeImageCacheAdapterMock.storeCoverImage.mockReset();
    nativeImageCacheAdapterMock.storeCoverImage.mockResolvedValue(null);
    const nativeImageCacheModule = await import("./native-image-cache-adapter");
    vi.mocked(
      nativeImageCacheModule.isNativeImageCacheAdapterAvailable,
    ).mockReturnValue(false);
    await idbClear(cacheIndexStore);
    await _resetLibraryDbForTests();
    useCacheIndexStore.setState({ items: {}, loaded: true, downloads: {} });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns cached cover URL when cover is cached", async () => {
    const blob = new Blob(["cover"], { type: "image/jpeg" });
    cacheStorageMock.get.mockImplementation(async (key: string) => {
      if (key === "cover:cover-1") return blob;
      return null;
    });

    useCacheIndexStore.setState({
      items: {
        "cover:cover-1": {
          id: "cover-1",
          type: "cover",
          source: "explicit",
          coverSize: "700",
          sizeBytes: blob.size,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    const url = await cacheManager.getCachedCoverUrl("cover-1");

    expect(url).toBeTruthy();
  });

  it("returns higher-quality cached covers for lower-size requests", async () => {
    const blob = new Blob(["cover"], { type: "image/jpeg" });
    cacheStorageMock.get.mockImplementation(async (key: string) => {
      if (key === "cover:cover-high") return blob;
      return null;
    });

    useCacheIndexStore.setState({
      items: {
        "cover:cover-high": {
          id: "cover-high",
          type: "cover",
          source: "explicit",
          coverSize: "700",
          sizeBytes: blob.size,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    const url = await cacheManager.getCachedCoverUrl("cover-high", "100");

    expect(url).toBeTruthy();
    expect(cacheStorageMock.get).toHaveBeenCalledWith("cover:cover-high");
  });

  it("does not satisfy higher-size requests with smaller cached covers", async () => {
    useCacheIndexStore.setState({
      items: {
        "cover:cover-small": {
          id: "cover-small",
          type: "cover",
          source: "explicit",
          coverSize: "100",
          sizeBytes: 5,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    const url = await cacheManager.getCachedCoverUrl("cover-small", "700");

    expect(url).toBeNull();
    expect(cacheStorageMock.get).not.toHaveBeenCalled();
  });

  it("returns cached cover URL even when index is empty (blob exists in Cache API)", async () => {
    const blob = new Blob(["cover"], { type: "image/jpeg" });
    cacheStorageMock.get.mockImplementation(async (key: string) => {
      if (key === "cover:cover-2") return blob;
      return null;
    });

    // Simulate startup before loadFromIDB has finished: index is empty.
    useCacheIndexStore.setState({ items: {}, loaded: false });

    const { cacheManager } = await import("./cache-manager");
    const url = await cacheManager.getCachedCoverUrl("cover-2");

    expect(url).toBeTruthy();
  });

  it("deduplicates concurrent native cached cover resolves", async () => {
    const nativeImageCacheModule = await import("./native-image-cache-adapter");
    vi.mocked(
      nativeImageCacheModule.isNativeImageCacheAdapterAvailable,
    ).mockReturnValue(true);

    let resolveNative: (
      value: Awaited<
        ReturnType<typeof nativeImageCacheAdapterMock.resolveCoverImage>
      >,
    ) => void = () => {};
    nativeImageCacheAdapterMock.resolveCoverImage.mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveNative = resolve;
        }),
    );

    useCacheIndexStore.setState({
      items: {
        "cover:native-cover-1": {
          id: "native-cover-1",
          type: "cover",
          source: "explicit",
          coverSize: "700",
          sizeBytes: 123,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    const first = cacheManager.getCachedCoverUrl("native-cover-1");
    const second = cacheManager.getCachedCoverUrl("native-cover-1");

    expect(nativeImageCacheAdapterMock.resolveCoverImage).toHaveBeenCalledTimes(
      1,
    );

    resolveNative({
      coverArtId: "native-cover-1",
      uri: "aonsoku-media://cached?id=native-cover-1",
      sizeBytes: 123,
      coverSize: "700",
    });

    await expect(Promise.all([first, second])).resolves.toEqual([
      "converted:aonsoku-media://cached?id=native-cover-1",
      "converted:aonsoku-media://cached?id=native-cover-1",
    ]);
  });

  it("reuses resolved native cached cover URLs without another adapter call", async () => {
    const nativeImageCacheModule = await import("./native-image-cache-adapter");
    vi.mocked(
      nativeImageCacheModule.isNativeImageCacheAdapterAvailable,
    ).mockReturnValue(true);
    nativeImageCacheAdapterMock.resolveCoverImage.mockResolvedValue({
      coverArtId: "native-cover-2",
      uri: "aonsoku-media://cached?id=native-cover-2",
      sizeBytes: 456,
      coverSize: "700",
    });

    useCacheIndexStore.setState({
      items: {
        "cover:native-cover-2": {
          id: "native-cover-2",
          type: "cover",
          source: "explicit",
          coverSize: "700",
          sizeBytes: 456,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    const first = await cacheManager.getCachedCoverUrl("native-cover-2");
    const second = await cacheManager.getCachedCoverUrl("native-cover-2");

    expect(first).toBe("converted:aonsoku-media://cached?id=native-cover-2");
    expect(second).toBe(first);
    expect(nativeImageCacheAdapterMock.resolveCoverImage).toHaveBeenCalledTimes(
      1,
    );
  });

  it("replaces smaller cover with larger size", async () => {
    const bigBlob = new Blob(["big-cover"], { type: "image/jpeg" });

    cacheStorageMock.get.mockResolvedValue(null);

    useCacheIndexStore.setState({
      items: {
        "cover:cover-1": {
          id: "cover-1",
          type: "cover",
          source: "explicit",
          coverSize: "300",
          sizeBytes: 5,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce({
      ok: true,
      blob: () => Promise.resolve(bigBlob),
    } as Response);

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.cacheCover("cover-1", "700");

    expect(cacheStorageMock.delete).toHaveBeenCalledWith("cover:cover-1");
    expect(cacheStorageMock.put).toHaveBeenCalledWith(
      "cover:cover-1",
      bigBlob,
      "image/jpeg",
    );

    await vi.waitFor(async () => {
      const meta = await libraryDb.cacheMeta.get("cover:cover-1");
      expect(meta).not.toBeUndefined();
      expect(meta?.coverSize).toBe("700");
      expect(meta?.sizeBytes).toBe(bigBlob.size);
    });

    vi.restoreAllMocks();
  });

  it("cacheSong sets download progress and delegates to audioCacheService", async () => {
    useCacheIndexStore.setState({
      items: {},
      loaded: true,
      downloads: {},
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.cacheSong("song-1");

    expect(audioCacheServiceMock.cacheSong).toHaveBeenCalledWith({
      songId: "song-1",
      priority: Priority.Explicit,
      source: "explicit",
    });
    expect(useCacheIndexStore.getState().downloads["song-1"]).toBe(0);
  });

  it("loadFromIDB restores audio cached state from cacheMeta only", async () => {
    await libraryDb.cacheMeta.put({
      key: "audio:song-restore",
      id: "song-restore",
      type: "audio",
      source: "explicit",
      sizeBytes: 123,
      cachedAt: 1,
      lastAccessedAt: 1,
    });
    useCacheIndexStore.setState({ items: {}, loaded: false, downloads: {} });

    await useCacheIndexStore.getState().actions.loadFromIDB();

    expect(isAudioCached("song-restore")).toBe(true);
  });

  it("cacheSong skips download when the audio index entry already exists", async () => {
    useCacheIndexStore.setState({
      items: {
        "audio:song-1": {
          id: "song-1",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
      downloads: {},
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.cacheSong("song-1");

    expect(audioCacheServiceMock.cacheSong).not.toHaveBeenCalled();
  });

  it("clearAllCaches also clears prefetched lyrics rows", async () => {
    await libraryDb.lyrics.put({
      songId: "song-1",
      content: "[]",
      cachedAt: 1,
      lastAccessedAt: 1,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.clearAllCaches();

    expect(await libraryDb.lyrics.count()).toBe(0);
    expect(cacheStorageMock.clear).toHaveBeenCalled();
    expect(
      nativeCacheHelpersMock.clearNativeAudioFilesIfAvailable,
    ).toHaveBeenCalledTimes(1);
  });

  it("clearAssets leaves lyrics rows intact", async () => {
    await libraryDb.lyrics.put({
      songId: "song-1",
      content: "[]",
      cachedAt: 1,
      lastAccessedAt: 1,
    });

    useCacheIndexStore.setState({
      items: {
        "cover:cover-1": {
          id: "cover-1",
          type: "cover",
          source: "explicit",
          sizeBytes: 10,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.clearAssets();

    expect(await libraryDb.lyrics.count()).toBe(1);
    expect(useCacheIndexStore.getState().items).toEqual({});
  });

  it("evictItem removes the row from libraryDb.cacheMeta", async () => {
    await libraryDb.cacheMeta.put({
      key: "audio:song-1",
      id: "song-1",
      type: "audio",
      source: "explicit",
      sizeBytes: 100,
      cachedAt: 1,
      lastAccessedAt: 1,
    });

    useCacheIndexStore.setState({
      items: {
        "audio:song-1": {
          id: "song-1",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.evictItem("audio:song-1");

    expect(await libraryDb.cacheMeta.get("audio:song-1")).toBeUndefined();
  });

  it("evictItem removes matching native audio files", async () => {
    useCacheIndexStore.setState({
      items: {
        "audio:song-1": {
          id: "song-1",
          type: "audio",
          source: "lru",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.evictItem("audio:song-1");

    expect(
      nativeCacheHelpersMock.evictNativeAudioFileIfAvailable,
    ).toHaveBeenCalledWith("song-1");
  });

  it("clearAudioBySource removes matching rows from libraryDb.cacheMeta", async () => {
    await libraryDb.cacheMeta.bulkPut([
      {
        key: "audio:song-1",
        id: "song-1",
        type: "audio",
        source: "explicit",
        sizeBytes: 100,
        cachedAt: 1,
        lastAccessedAt: 1,
      },
      {
        key: "audio:song-2",
        id: "song-2",
        type: "audio",
        source: "lru",
        sizeBytes: 200,
        cachedAt: 1,
        lastAccessedAt: 1,
      },
    ]);

    useCacheIndexStore.setState({
      items: {
        "audio:song-1": {
          id: "song-1",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
        "audio:song-2": {
          id: "song-2",
          type: "audio",
          source: "lru",
          sizeBytes: 200,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.clearAudioBySource("explicit");

    expect(await libraryDb.cacheMeta.get("audio:song-1")).toBeUndefined();
    expect(await libraryDb.cacheMeta.get("audio:song-2")).not.toBeUndefined();
  });

  it("clearAudioBySource removes matching native audio files", async () => {
    useCacheIndexStore.setState({
      items: {
        "audio:song-1": {
          id: "song-1",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
        "audio:song-2": {
          id: "song-2",
          type: "audio",
          source: "lru",
          sizeBytes: 200,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.clearAudioBySource("explicit");

    expect(
      nativeCacheHelpersMock.evictNativeAudioFileIfAvailable,
    ).toHaveBeenCalledWith("song-1");
    expect(
      nativeCacheHelpersMock.evictNativeAudioFileIfAvailable,
    ).not.toHaveBeenCalledWith("song-2");
  });

  it("self-heal for audio writes a synthetic row to libraryDb.cacheMeta when missing", async () => {
    const blob = new Blob(["audio"], { type: "audio/mpeg" });
    cacheStorageMock.get.mockImplementation(async (key: string) => {
      if (key === "audio:song-x") return blob;
      return null;
    });

    useCacheIndexStore.setState({ items: {}, loaded: false });

    const { cacheManager } = await import("./cache-manager");
    const url = await cacheManager.getCachedAudioUrl("song-x");

    expect(url).toBeTruthy();
    const meta = await libraryDb.cacheMeta.get("audio:song-x");
    expect(meta).not.toBeUndefined();
    expect(meta?.type).toBe("audio");
    expect(meta?.source).toBe("explicit");
  });

  it("getCachedAudioUrl returns null for non-cached song when index is loaded", async () => {
    cacheStorageMock.get.mockResolvedValue(null);
    useCacheIndexStore.setState({ items: {}, loaded: true });

    const { cacheManager } = await import("./cache-manager");
    const url = await cacheManager.getCachedAudioUrl("missing-song");

    expect(url).toBeNull();
  });

  it("getCachedAudioUrl removes stale index entry when blob is missing", async () => {
    cacheStorageMock.get.mockResolvedValue(null);
    useCacheIndexStore.setState({
      items: {
        "audio:stale": {
          id: "stale",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    const url = await cacheManager.getCachedAudioUrl("stale");

    expect(url).toBeNull();
    expect(useCacheIndexStore.getState().items["audio:stale"]).toBeUndefined();
  });

  it("cacheSmartSong upgrades lru to smart with triggers", async () => {
    audioCacheServiceMock.cacheSong.mockResolvedValue(undefined);
    useCacheIndexStore.setState({
      items: {
        "audio:smart-me": {
          id: "smart-me",
          type: "audio",
          source: "lru",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.cacheSmartSong("smart-me", ["favorite"]);

    const item = useCacheIndexStore.getState().items["audio:smart-me"];
    expect(item.source).toBe("smart");
    expect(item.triggers).toEqual(["favorite"]);
    audioCacheServiceMock.cacheSong.mockReset();
  });

  it("cacheSmartSong does not demote explicit entries", async () => {
    useCacheIndexStore.setState({
      items: {
        "audio:explicit-song": {
          id: "explicit-song",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.cacheSmartSong("explicit-song", ["favorite"]);

    expect(audioCacheServiceMock.cacheSong).not.toHaveBeenCalled();
  });

  it("cacheSmartSong caches new song via audioCacheService", async () => {
    audioCacheServiceMock.cacheSong.mockResolvedValue(undefined);
    useCacheIndexStore.setState({ items: {}, loaded: true });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.cacheSmartSong("new-song", ["playlist"]);

    expect(audioCacheServiceMock.cacheSong).toHaveBeenCalledWith({
      songId: "new-song",
      priority: 0,
      source: "smart",
      triggers: ["playlist"],
    });
  });

  it("reconcileRemovedFromServer marks missing songs and skips when majority missing", async () => {
    await libraryDb.songs.bulkPut([
      {
        id: "s1",
        parent: "a",
        title: "S1",
        album: "A",
        artist: "X",
        track: 1,
        year: 2024,
        coverArt: "",
        size: 1,
        contentType: "audio/mpeg",
        suffix: "mp3",
        duration: 180,
        bitRate: 320,
        path: "p1",
        discNumber: 1,
        created: "2024-01-01T00:00:00.000Z",
        albumId: "a",
        artistId: "x",
        type: "music",
        isVideo: false,
        bpm: 0,
        comment: "",
        sortName: "S1",
        mediaType: "song",
        musicBrainzId: "",
        genres: [],
        replayGain: { trackGain: 0, trackPeak: 0, albumGain: 0, albumPeak: 0 },
      },
    ]);

    useCacheIndexStore.setState({
      items: {
        "audio:s1": {
          id: "s1",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
        "audio:missing": {
          id: "missing",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
        "audio:also-missing": {
          id: "also-missing",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { cacheManager } = await import("./cache-manager");
    await cacheManager.reconcileRemovedFromServer();

    expect(warnSpy).toHaveBeenCalled();
    warnSpy.mockRestore();
  });

  it("reconcileRemovedFromServer marks entries whose songId is gone from server", async () => {
    await libraryDb.songs.bulkPut([
      {
        id: "s1",
        parent: "a",
        title: "S1",
        album: "A",
        artist: "X",
        track: 1,
        year: 2024,
        coverArt: "",
        size: 1,
        contentType: "audio/mpeg",
        suffix: "mp3",
        duration: 180,
        bitRate: 320,
        path: "p1",
        discNumber: 1,
        created: "2024-01-01T00:00:00.000Z",
        albumId: "a",
        artistId: "x",
        type: "music",
        isVideo: false,
        bpm: 0,
        comment: "",
        sortName: "S1",
        mediaType: "song",
        musicBrainzId: "",
        genres: [],
        replayGain: { trackGain: 0, trackPeak: 0, albumGain: 0, albumPeak: 0 },
      },
      {
        id: "s2",
        parent: "a",
        title: "S2",
        album: "A",
        artist: "X",
        track: 2,
        year: 2024,
        coverArt: "",
        size: 1,
        contentType: "audio/mpeg",
        suffix: "mp3",
        duration: 180,
        bitRate: 320,
        path: "p2",
        discNumber: 1,
        created: "2024-01-01T00:00:00.000Z",
        albumId: "a",
        artistId: "x",
        type: "music",
        isVideo: false,
        bpm: 0,
        comment: "",
        sortName: "S2",
        mediaType: "song",
        musicBrainzId: "",
        genres: [],
        replayGain: { trackGain: 0, trackPeak: 0, albumGain: 0, albumPeak: 0 },
      },
    ]);

    useCacheIndexStore.setState({
      items: {
        "audio:s1": {
          id: "s1",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
        "audio:deleted-song": {
          id: "deleted-song",
          type: "audio",
          source: "explicit",
          sizeBytes: 100,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.reconcileRemovedFromServer();

    const items = useCacheIndexStore.getState().items;
    expect(items["audio:deleted-song"].removedFromServer).toBe(true);
    expect(items["audio:s1"].removedFromServer).toBeUndefined();
  });

  it("cacheCover returns early when existing cover size is >= requested size", async () => {
    useCacheIndexStore.setState({
      items: {
        "cover:cover-existing": {
          id: "cover-existing",
          type: "cover",
          source: "explicit",
          coverSize: "700",
          sizeBytes: 500,
          cachedAt: 1,
          lastAccessedAt: 1,
        },
      },
      loaded: true,
    });

    const { cacheManager } = await import("./cache-manager");
    await cacheManager.cacheCover("cover-existing", "300");

    expect(cacheStorageMock.put).not.toHaveBeenCalled();
  });

  it("limits concurrent cover downloads on cache miss", async () => {
    let activeFetches = 0;
    let maxActiveFetches = 0;
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      activeFetches++;
      maxActiveFetches = Math.max(maxActiveFetches, activeFetches);
      await new Promise((resolve) => setTimeout(resolve, 10));
      activeFetches--;
      return {
        ok: true,
        blob: () =>
          Promise.resolve(new Blob(["cover"], { type: "image/jpeg" })),
      } as Response;
    });

    const { cacheManager } = await import("./cache-manager");
    await Promise.all(
      Array.from({ length: 8 }, (_, index) =>
        cacheManager.cacheCover(`cover-miss-${index}`, "300"),
      ),
    );

    expect(maxActiveFetches).toBeLessThanOrEqual(4);
    expect(globalThis.fetch).toHaveBeenCalledTimes(8);
    expect(cacheStorageMock.put).toHaveBeenCalledTimes(8);
  });

  it("isDownloadQueued checks both queue and in-flight status", async () => {
    audioCacheServiceMock.isQueued.mockReturnValue(true);
    audioCacheServiceMock.isInFlight.mockReturnValue(false);

    const { cacheManager } = await import("./cache-manager");
    expect(cacheManager.isDownloadQueued("song-1")).toBe(true);

    audioCacheServiceMock.isQueued.mockReturnValue(false);
    audioCacheServiceMock.isInFlight.mockReturnValue(true);
    expect(cacheManager.isDownloadQueued("song-1")).toBe(true);

    audioCacheServiceMock.isQueued.mockReturnValue(false);
    audioCacheServiceMock.isInFlight.mockReturnValue(false);
    expect(cacheManager.isDownloadQueued("song-1")).toBe(false);
  });
});
