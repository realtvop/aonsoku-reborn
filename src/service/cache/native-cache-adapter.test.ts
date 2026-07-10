import { afterEach, describe, expect, it, vi } from "vitest";
import type { NativeAudioPlugin } from "@/native/audio";
import { FakeNativeCacheAdapter } from "./contracts/fakes";
import type { NativeCacheAdapter } from "./contracts";
import {
  _resetNativeCacheAdapter,
  _setNativeCacheAdapterForTests,
  clearNativeAudioFilesIfAvailable,
  evictNativeAudioFileIfAvailable,
  getNativeCacheAdapter,
  IosNativeCacheAdapter,
  isNativeCacheAdapterAvailable,
  storeNativeAudioFileIfAvailable,
} from "./native-cache-adapter";

const mocks = vi.hoisted(() => ({
  getRuntime: vi.fn(),
  getNativeAudioPluginAvailability: vi.fn(),
}));

vi.mock("@/utils/capabilities", () => ({
  getRuntime: mocks.getRuntime,
}));

vi.mock("@/native/audio", () => ({
  getNativeAudioPluginAvailability: mocks.getNativeAudioPluginAvailability,
}));

function createNativePlugin(): NativeAudioPlugin {
  return {
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
      uri: "file:///native-cache/song-1.mp3",
      contentType: "audio/mpeg",
      sizeBytes: 4,
      lastModifiedAt: 123,
    })),
    resolveAudioFile: vi.fn(async () => ({
      file: {
        songId: "song-1",
        uri: "file:///native-cache/song-1.mp3",
        contentType: "audio/mpeg",
        sizeBytes: 4,
        lastModifiedAt: 123,
      },
    })),
    getAudioFileSize: vi.fn(async () => ({ sizeBytes: 4 })),
    deleteAudioFile: vi.fn(async () => ({ deleted: true })),
    clearAudioFiles: vi.fn(async () => ({ deletedCount: 2 })),
    addListener: vi.fn(async () => ({ remove: vi.fn(async () => {}) })),
    removeAllListeners: vi.fn(async () => {}),
  };
}

afterEach(() => {
  _resetNativeCacheAdapter();
  vi.restoreAllMocks();
});

describe("getNativeCacheAdapter", () => {
  it("returns a null adapter on web platform", () => {
    mocks.getRuntime.mockReturnValue("web");
    const adapter = getNativeCacheAdapter();

    expect(adapter).toBeDefined();
  });

  it("web null adapter returns null for resolve", async () => {
    mocks.getRuntime.mockReturnValue("web");
    const adapter = getNativeCacheAdapter();

    expect(await adapter.resolveAudioFile("song-1")).toBeNull();
  });

  it("web null adapter returns null for size", async () => {
    mocks.getRuntime.mockReturnValue("web");
    const adapter = getNativeCacheAdapter();

    expect(await adapter.getAudioFileSize("song-1")).toBeNull();
  });

  it("web null adapter returns false for delete", async () => {
    mocks.getRuntime.mockReturnValue("web");
    const adapter = getNativeCacheAdapter();

    expect(await adapter.deleteAudioFile("song-1")).toBe(false);
  });

  it("web null adapter returns false for evict", async () => {
    mocks.getRuntime.mockReturnValue("web");
    const adapter = getNativeCacheAdapter();

    expect(await adapter.evictAudioFile("song-1")).toBe(false);
  });

  it("web null adapter clears as a no-op", async () => {
    mocks.getRuntime.mockReturnValue("web");
    const adapter = getNativeCacheAdapter();

    await expect(adapter.clearAudioFiles()).resolves.toBeUndefined();
  });

  it("web null adapter throws on store", async () => {
    mocks.getRuntime.mockReturnValue("web");
    const adapter = getNativeCacheAdapter();

    await expect(
      adapter.storeAudioFile("song-1", new Blob(["x"]), "audio/mpeg"),
    ).rejects.toThrow("NativeCacheAdapter is not available on web platform");
  });

  it("returns the iOS adapter when the native plugin is available", () => {
    const plugin = createNativePlugin();
    mocks.getRuntime.mockReturnValue("capacitor-ios");
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: true,
      plugin,
    });

    expect(getNativeCacheAdapter()).toBeInstanceOf(IosNativeCacheAdapter);
    expect(isNativeCacheAdapterAvailable()).toBe(true);
  });

  it("returns the adapter on Android when the native plugin is available", () => {
    const plugin = createNativePlugin();
    mocks.getRuntime.mockReturnValue("capacitor-android");
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: true,
      plugin,
    });

    expect(getNativeCacheAdapter()).toBeInstanceOf(IosNativeCacheAdapter);
    expect(isNativeCacheAdapterAvailable()).toBe(true);
  });

  it("returns the adapter on Electron when the native plugin is available", () => {
    const plugin = createNativePlugin();
    mocks.getRuntime.mockReturnValue("electron");
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: true,
      plugin,
    });

    expect(getNativeCacheAdapter()).toBeInstanceOf(IosNativeCacheAdapter);
    expect(isNativeCacheAdapterAvailable()).toBe(true);
  });

  it("returns a null adapter on iOS when the native plugin is missing", async () => {
    mocks.getRuntime.mockReturnValue("capacitor-ios");
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: false,
      reason: "missing-plugin",
      message: "missing",
    });

    const adapter = getNativeCacheAdapter();

    expect(isNativeCacheAdapterAvailable()).toBe(false);
    expect(await adapter.resolveAudioFile("song-1")).toBeNull();
  });

  it("returns a null adapter on capacitor-android when native plugin is unavailable", async () => {
    mocks.getRuntime.mockReturnValue("capacitor-android");
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: false,
      reason: "unsupported-platform",
      message: "not yet implemented",
    });

    const adapter = getNativeCacheAdapter();

    expect(isNativeCacheAdapterAvailable()).toBe(false);
    expect(await adapter.resolveAudioFile("song-1")).toBeNull();
  });

  it("caches the adapter instance", () => {
    mocks.getRuntime.mockReturnValue("web");
    const a = getNativeCacheAdapter();
    const b = getNativeCacheAdapter();
    expect(a).toBe(b);
  });

  it("reset clears the cached adapter", () => {
    mocks.getRuntime.mockReturnValue("web");
    const a = getNativeCacheAdapter();
    _resetNativeCacheAdapter();
    const b = getNativeCacheAdapter();
    expect(a).not.toBe(b);
  });

  it("allows injecting a test adapter", () => {
    const fake: NativeCacheAdapter = new FakeNativeCacheAdapter();
    _setNativeCacheAdapterForTests(fake);
    const adapter = getNativeCacheAdapter();
    expect(adapter).toBe(fake);
  });
});

describe("IosNativeCacheAdapter", () => {
  it("stores blobs through the native plugin as base64", async () => {
    const plugin = createNativePlugin();
    const adapter = new IosNativeCacheAdapter(plugin);

    const stored = await adapter.storeAudioFile(
      "song-1",
      new Blob(["test"]),
      "audio/mpeg",
    );

    expect(plugin.storeAudioFile).toHaveBeenCalledWith({
      songId: "song-1",
      dataBase64: "dGVzdA==",
      contentType: "audio/mpeg",
    });
    expect(stored).toEqual({
      songId: "song-1",
      uri: "file:///native-cache/song-1.mp3",
      contentType: "audio/mpeg",
      sizeBytes: 4,
      lastModifiedAt: 123,
    });
  });

  it("resolves, sizes, deletes, evicts, and clears through the plugin", async () => {
    const plugin = createNativePlugin();
    const adapter = new IosNativeCacheAdapter(plugin);

    await expect(adapter.resolveAudioFile("song-1")).resolves.toEqual({
      songId: "song-1",
      uri: "file:///native-cache/song-1.mp3",
      contentType: "audio/mpeg",
      sizeBytes: 4,
      lastModifiedAt: 123,
    });
    await expect(adapter.getAudioFileSize("song-1")).resolves.toBe(4);
    await expect(adapter.deleteAudioFile("song-1")).resolves.toBe(true);
    await expect(adapter.evictAudioFile("song-1")).resolves.toBe(true);
    await expect(adapter.clearAudioFiles()).resolves.toBeUndefined();

    expect(plugin.resolveAudioFile).toHaveBeenCalledWith({ songId: "song-1" });
    expect(plugin.getAudioFileSize).toHaveBeenCalledWith({ songId: "song-1" });
    expect(plugin.deleteAudioFile).toHaveBeenCalledWith({ songId: "song-1" });
    expect(plugin.clearAudioFiles).toHaveBeenCalledTimes(1);
  });

  it("normalizes missing native file results", async () => {
    const plugin = createNativePlugin();
    vi.mocked(plugin.resolveAudioFile).mockResolvedValue({ file: null });
    vi.mocked(plugin.getAudioFileSize).mockResolvedValue({ sizeBytes: null });
    const adapter = new IosNativeCacheAdapter(plugin);

    await expect(adapter.resolveAudioFile("missing")).resolves.toBeNull();
    await expect(adapter.getAudioFileSize("missing")).resolves.toBeNull();
  });
});

describe("native cache availability helpers", () => {
  it("stores, evicts, and clears only when native iOS cache is available", async () => {
    const plugin = createNativePlugin();
    mocks.getRuntime.mockReturnValue("capacitor-ios");
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: true,
      plugin,
    });

    await expect(
      storeNativeAudioFileIfAvailable(
        "song-1",
        new Blob(["test"]),
        "audio/mpeg",
      ),
    ).resolves.toMatchObject({ songId: "song-1" });
    await expect(evictNativeAudioFileIfAvailable("song-1")).resolves.toBe(true);
    await expect(clearNativeAudioFilesIfAvailable()).resolves.toBeUndefined();
  });

  it("no-ops helper calls when native iOS cache is unavailable", async () => {
    mocks.getRuntime.mockReturnValue("web");
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: false,
      reason: "unsupported-platform",
      message: "not a native platform",
    });

    await expect(
      storeNativeAudioFileIfAvailable(
        "song-1",
        new Blob(["test"]),
        "audio/mpeg",
      ),
    ).resolves.toBeNull();
    await expect(evictNativeAudioFileIfAvailable("song-1")).resolves.toBe(
      false,
    );
    await expect(clearNativeAudioFilesIfAvailable()).resolves.toBeUndefined();
  });
});
