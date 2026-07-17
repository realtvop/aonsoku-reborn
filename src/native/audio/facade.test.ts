import { Capacitor, registerPlugin } from "@capacitor/core";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NativeAudioEventName, NativeAudioPlugin } from ".";
import {
  AonsokuNativeAudio,
  addNativeAudioListener,
  getNativeAudioPluginAvailability,
  isNativeAudioPluginAvailable,
  NATIVE_AUDIO_PLUGIN_NAME,
  tryAddNativeAudioListener,
} from ".";

const mocks = vi.hoisted(() => {
  class MockWebPlugin {
    protected listeners: Record<string, ((event: unknown) => void)[]> = {};

    addListener(
      eventName: string,
      listenerFunc: (event: unknown) => void,
    ): Promise<{ remove: () => Promise<void> }> {
      this.listeners[eventName] ??= [];
      this.listeners[eventName].push(listenerFunc);

      return Promise.resolve({
        remove: async () => {
          this.listeners[eventName] = this.listeners[eventName].filter(
            (listener) => listener !== listenerFunc,
          );
        },
      });
    }

    removeAllListeners(): Promise<void> {
      this.listeners = {};
      return Promise.resolve();
    }
  }

  const mockPlugin = {
    load: vi.fn(),
    play: vi.fn(),
    pause: vi.fn(),
    stop: vi.fn(),
    seek: vi.fn(),
    setRepeatMode: vi.fn(),
    setShuffle: vi.fn(),
    markAsShuffled: vi.fn(),
    setQueue: vi.fn(),
    skipToNext: vi.fn(),
    skipToPrevious: vi.fn(),
    updateMetadata: vi.fn(),
    updateRemotePlaybackState: vi.fn(),
    clearRemotePlaybackState: vi.fn(),
    preload: vi.fn(),
    clear: vi.fn(),
    storeAudioFile: vi.fn(),
    resolveAudioFile: vi.fn(),
    getAudioFileSize: vi.fn(),
    deleteAudioFile: vi.fn(),
    clearAudioFiles: vi.fn(),
    setContextQueue: vi.fn(),
    updateContextQueue: vi.fn(),
    reorderContextQueue: vi.fn(),
    addToUserQueue: vi.fn(),
    removeFromUserQueue: vi.fn(),
    clearUserQueue: vi.fn(),
    playAtIndex: vi.fn(),
    getFullState: vi.fn(),
    resolveSongs: vi.fn(),
    getScrobbleBuffer: vi.fn(),
    clearScrobbleBuffer: vi.fn(),
    downloadAudioFile: vi.fn(),
    cancelDownload: vi.fn(),
    setSystemVolume: vi.fn(),
    getSystemVolume: vi.fn(),
    setVolumeHUDEnabled: vi.fn(),
    setLikeActive: vi.fn(),
    setSleepTimer: vi.fn(),
    cancelSleepTimer: vi.fn(),
    getSleepTimerRemaining: vi.fn(),
    addListener: vi.fn(),
    removeAllListeners: vi.fn(),
  };

  return {
    MockWebPlugin,
    mockPlugin,
    mockIsNativePlatform: vi.fn(),
    mockGetPlatform: vi.fn(),
    mockIsPluginAvailable: vi.fn(),
    mockRegisterPlugin: vi.fn(() => mockPlugin),
  };
});

vi.mock("@capacitor/core", () => ({
  Capacitor: {
    isNativePlatform: mocks.mockIsNativePlatform,
    getPlatform: mocks.mockGetPlatform,
    isPluginAvailable: mocks.mockIsPluginAvailable,
  },
  registerPlugin: mocks.mockRegisterPlugin,
  WebPlugin: mocks.MockWebPlugin,
}));

const mockIsNativePlatform = vi.mocked(Capacitor.isNativePlatform);
const mockGetPlatform = vi.mocked(Capacitor.getPlatform);
const mockIsPluginAvailable = vi.mocked(Capacitor.isPluginAvailable);
const mockRegisterPlugin = vi.mocked(registerPlugin);
const mockPlugin = mocks.mockPlugin as NativeAudioPlugin;

describe("Aonsoku native audio facade", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    mockIsNativePlatform.mockReset();
    mockGetPlatform.mockReset();
    mockIsPluginAvailable.mockReset();
    for (const value of Object.values(mockPlugin)) {
      if (typeof value === "function") {
        vi.mocked(value).mockReset();
      }
    }
    mockIsNativePlatform.mockReturnValue(false);
    mockGetPlatform.mockReturnValue("web");
    mockIsPluginAvailable.mockReturnValue(false);
  });

  it("registers the typed Capacitor plugin with a web fallback", async () => {
    expect(mockRegisterPlugin).toHaveBeenCalledWith(NATIVE_AUDIO_PLUGIN_NAME, {
      web: expect.any(Function),
    });
    expect(AonsokuNativeAudio).toBe(mockPlugin);

    const implementations = mockRegisterPlugin.mock.calls[0]?.[1] ?? {};
    const webImplementation = await implementations.web();

    await expect(
      webImplementation.load({
        source: {
          kind: "stream",
          url: "https://server/rest/stream?id=song-1",
          songId: "song-1",
        },
      }),
    ).rejects.toThrow(
      "AonsokuNativeAudio.load is only available on Electron desktop or native Capacitor platforms",
    );
  });

  it("prefers the Electron desktop bridge when it is exposed", () => {
    vi.stubGlobal("window", {
      aonsokuNativeAudio: mockPlugin,
      aonsokuNativeAudioCapability: { available: true },
    });

    expect(getNativeAudioPluginAvailability()).toEqual({
      available: true,
      plugin: mockPlugin,
    });
    expect(mockIsNativePlatform).not.toHaveBeenCalled();
    expect(isNativeAudioPluginAvailable()).toBe(true);
  });

  it("rejects an Electron bridge that did not pass its health handshake", () => {
    vi.stubGlobal("window", {
      aonsokuNativeAudio: mockPlugin,
      aonsokuNativeAudioCapability: {
        available: false,
        reason: "native addon unavailable",
      },
    });

    expect(getNativeAudioPluginAvailability()).toEqual({
      available: false,
      reason: "unhealthy-plugin",
      message: "native addon unavailable",
    });
  });

  it("reports unsupported platforms as unavailable", () => {
    expect(getNativeAudioPluginAvailability()).toEqual({
      available: false,
      reason: "unsupported-platform",
      message:
        "AonsokuNativeAudio requires Electron desktop or a native Capacitor platform.",
    });
    expect(isNativeAudioPluginAvailable()).toBe(false);

    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("android");

    expect(getNativeAudioPluginAvailability()).toMatchObject({
      available: false,
      reason: "missing-plugin",
    });

    mockIsPluginAvailable.mockReturnValue(true);
    expect(getNativeAudioPluginAvailability()).toEqual({
      available: true,
      plugin: mockPlugin,
    });
  });

  it("reports Capacitor iOS as unavailable when the plugin is missing", () => {
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    mockIsPluginAvailable.mockReturnValue(false);

    expect(getNativeAudioPluginAvailability()).toEqual({
      available: false,
      reason: "missing-plugin",
      message: "AonsokuNativeAudio native plugin is not available on ios.",
    });
  });

  it("returns the registered plugin when Capacitor iOS exposes it", () => {
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    mockIsPluginAvailable.mockReturnValue(true);

    expect(getNativeAudioPluginAvailability()).toEqual({
      available: true,
      plugin: mockPlugin,
    });
    expect(isNativeAudioPluginAvailable()).toBe(true);
    expect(mockIsPluginAvailable).toHaveBeenCalledWith(
      NATIVE_AUDIO_PLUGIN_NAME,
    );
  });

  it("adds typed listeners through the Electron desktop bridge", async () => {
    const handle = { remove: vi.fn() };
    const listener = vi.fn();
    vi.mocked(mockPlugin.addListener).mockResolvedValue(handle);
    vi.stubGlobal("window", {
      aonsokuNativeAudio: mockPlugin,
      aonsokuNativeAudioCapability: { available: true },
    });

    await expect(addNativeAudioListener("progress", listener)).resolves.toBe(
      handle,
    );

    expect(mockPlugin.addListener).toHaveBeenCalledWith(
      "progress" satisfies NativeAudioEventName,
      listener,
    );
    expect(mockIsNativePlatform).not.toHaveBeenCalled();
  });

  it("adds typed listeners through the native Capacitor plugin", async () => {
    const handle = { remove: vi.fn() };
    const listener = vi.fn();
    vi.mocked(mockPlugin.addListener).mockResolvedValue(handle);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    mockIsPluginAvailable.mockReturnValue(true);

    await expect(addNativeAudioListener("progress", listener)).resolves.toBe(
      handle,
    );

    expect(mockPlugin.addListener).toHaveBeenCalledWith(
      "progress" satisfies NativeAudioEventName,
      listener,
    );
  });

  it("returns null for optional listeners when native audio is unavailable", async () => {
    await expect(
      tryAddNativeAudioListener("ended", vi.fn()),
    ).resolves.toBeNull();
    await expect(addNativeAudioListener("ended", vi.fn())).rejects.toThrow(
      "AonsokuNativeAudio requires Electron desktop or a native Capacitor platform.",
    );
  });
});
