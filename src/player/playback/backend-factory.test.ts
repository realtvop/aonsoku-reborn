import { describe, expect, it, vi } from "vitest";
import type { NativeAudioPlugin } from "@/native/audio";
import {
  createPlaybackBackend,
  shouldUseNativePlaybackBackend,
  type PlaybackBackend,
} from ".";
import type { PlaybackCapabilities } from "@/utils/capabilities";

function makeAudio() {
  return {} as HTMLAudioElement;
}

function makeBackend(): PlaybackBackend {
  return {
    load: vi.fn(),
    play: vi.fn(),
    pause: vi.fn(),
    stop: vi.fn(),
    seek: vi.fn(),
    setLoop: vi.fn(),
    setRepeatMode: vi.fn(),
    setShuffle: vi.fn(),
    skipToNext: vi.fn(),
    skipToPrevious: vi.fn(),
    setVolume: vi.fn(),
    updateMetadata: vi.fn(),
    preload: vi.fn(),
    dispose: vi.fn(),
    subscribe: vi.fn(() => vi.fn()),
  };
}

function makeAvailablePlugin() {
  return {
    available: true,
    plugin: {} as NativeAudioPlugin,
  } as const;
}

function caps(overrides?: Partial<PlaybackCapabilities>): PlaybackCapabilities {
  return {
    canSetVolume: true,
    requiresSystemVolume: false,
    supportsSystemVolumeControl: false,
    supportsWebAudioReplayGain: true,
    supportsNativePlayback: false,
    supportsBackgroundPlayback: false,
    ...overrides,
  };
}

describe("playback backend selection", () => {
  it("uses the web backend when native playback is not supported", () => {
    const webBackend = makeBackend();
    const nativeBackend = makeBackend();

    const selection = createPlaybackBackend(makeAudio(), {
      getCapabilities: () => caps({ supportsNativePlayback: false }),
      getNativeAudioAvailability: makeAvailablePlugin,
      createWebBackend: () => webBackend,
      createNativeBackend: () => nativeBackend,
    });

    expect(selection).toEqual({
      backend: webBackend,
      kind: "web",
    });
  });

  it("uses the native backend when Capacitor iOS exposes the plugin", () => {
    const webBackend = makeBackend();
    const nativeBackend = makeBackend();

    const selection = createPlaybackBackend(makeAudio(), {
      getCapabilities: () => caps({ supportsNativePlayback: true }),
      getNativeAudioAvailability: makeAvailablePlugin,
      createWebBackend: () => webBackend,
      createNativeBackend: () => nativeBackend,
    });

    expect(selection).toEqual({
      backend: nativeBackend,
      kind: "native",
    });
  });

  it("prefers the Electron sidecar backend when it is feature-flagged", () => {
    const webBackend = makeBackend();
    const nativeBackend = makeBackend();
    const sidecarBackend = makeBackend();

    const selection = createPlaybackBackend(makeAudio(), {
      getCapabilities: () => caps({ supportsNativePlayback: true }),
      getSidecarAvailability: () => ({
        available: true,
        api: {} as Window["api"]["audioSidecar"],
      }),
      getNativeAudioAvailability: makeAvailablePlugin,
      createWebBackend: () => webBackend,
      createNativeBackend: () => nativeBackend,
      createSidecarBackend: () => sidecarBackend,
    });

    expect(selection).toEqual({
      backend: sidecarBackend,
      kind: "sidecar",
    });
  });

  it("falls back to web when the plugin is missing", () => {
    const webBackend = makeBackend();
    const nativeFactory = vi.fn(() => makeBackend());

    const selection = createPlaybackBackend(makeAudio(), {
      getCapabilities: () => caps({ supportsNativePlayback: true }),
      getNativeAudioAvailability: () => ({
        available: false,
        reason: "missing-plugin",
        message: "missing",
      }),
      createWebBackend: () => webBackend,
      createNativeBackend: nativeFactory,
    });

    expect(selection).toEqual({
      backend: webBackend,
      kind: "web",
      fallbackReason: "missing-plugin",
    });
    expect(nativeFactory).not.toHaveBeenCalled();
  });

  it("falls back to web if native backend construction fails", () => {
    const webBackend = makeBackend();

    const selection = createPlaybackBackend(makeAudio(), {
      getCapabilities: () => caps({ supportsNativePlayback: true }),
      getNativeAudioAvailability: makeAvailablePlugin,
      createWebBackend: () => webBackend,
      createNativeBackend: () => {
        throw new Error("native unavailable");
      },
    });

    expect(selection).toEqual({
      backend: webBackend,
      kind: "web",
      fallbackReason: "native unavailable",
    });
  });

  it("falls back to web if sidecar backend construction fails", () => {
    const webBackend = makeBackend();

    const selection = createPlaybackBackend(makeAudio(), {
      getCapabilities: () => caps({ supportsNativePlayback: false }),
      getSidecarAvailability: () => ({
        available: true,
        api: {} as Window["api"]["audioSidecar"],
      }),
      createWebBackend: () => webBackend,
      createSidecarBackend: () => {
        throw new Error("sidecar unavailable");
      },
    });

    expect(selection).toEqual({
      backend: webBackend,
      kind: "web",
      fallbackReason: "sidecar unavailable",
    });
  });

  it("reports whether native playback should be used", () => {
    expect(
      shouldUseNativePlaybackBackend({
        getCapabilities: () => caps({ supportsNativePlayback: false }),
        getNativeAudioAvailability: makeAvailablePlugin,
      }),
    ).toBe(false);
    expect(
      shouldUseNativePlaybackBackend({
        getCapabilities: () => caps({ supportsNativePlayback: true }),
        getNativeAudioAvailability: () => ({
          available: false,
          reason: "missing-plugin",
          message: "missing",
        }),
      }),
    ).toBe(false);
    expect(
      shouldUseNativePlaybackBackend({
        getCapabilities: () => caps({ supportsNativePlayback: true }),
        getNativeAudioAvailability: makeAvailablePlugin,
      }),
    ).toBe(true);
    expect(
      shouldUseNativePlaybackBackend({
        getCapabilities: () => caps({ supportsNativePlayback: false }),
        getSidecarAvailability: () => ({
          available: true,
          api: {} as Window["api"]["audioSidecar"],
        }),
      }),
    ).toBe(true);
  });
});
