import { describe, expect, it, vi } from "vitest";

import {
  createAudioSidecarDebugHarness,
  installAudioSidecarDebugHarness,
} from "./sidecar-debug";

type AudioSidecarApi = Window["api"]["audioSidecar"];

describe("audio sidecar debug harness", () => {
  it("does not install outside dev mode", async () => {
    const api = createFakeAudioSidecarApi();
    const target = createTarget(api);

    await expect(
      installAudioSidecarDebugHarness(target, { isDev: false }),
    ).resolves.toBeNull();

    expect(api.isAvailable).not.toHaveBeenCalled();
    expect(target.aonsokuAudioSidecarDebug).toBeUndefined();
  });

  it("does not install when the sidecar bridge is unavailable", async () => {
    const api = createFakeAudioSidecarApi({ available: false });
    const target = createTarget(api);

    await expect(
      installAudioSidecarDebugHarness(target, { isDev: true }),
    ).resolves.toBeNull();

    expect(target.aonsokuAudioSidecarDebug).toBeUndefined();
  });

  it("installs a small command surface when dev bridge is available", async () => {
    const api = createFakeAudioSidecarApi();
    const target = createTarget(api);

    const harness = await installAudioSidecarDebugHarness(target, {
      isDev: true,
    });

    expect(harness).toBe(target.aonsokuAudioSidecarDebug);

    await harness?.loadStream("https://example.test/song.flac", {
      autoplay: true,
      metadata: {
        duration: 30,
      },
    });
    await harness?.loadFile("/tmp/song.mp3");
    await harness?.seek(12);
    await harness?.stop();

    expect(api.load).toHaveBeenNthCalledWith(1, {
      autoplay: true,
      metadata: {
        duration: 30,
      },
      source: {
        kind: "stream",
        url: "https://example.test/song.flac",
      },
    });
    expect(api.load).toHaveBeenNthCalledWith(2, {
      source: {
        kind: "native-file",
        uri: "/tmp/song.mp3",
      },
    });
    expect(api.seek).toHaveBeenCalledWith({ position: 12 });
    expect(api.stopPlayback).toHaveBeenCalled();
  });

  it("collects events and removes listeners on dispose", async () => {
    const api = createFakeAudioSidecarApi();
    const harness = createAudioSidecarDebugHarness(api);

    api.emitEvent({
      event: "progress",
      payload: {
        currentTime: 1,
        duration: 10,
      },
    });
    api.emitError({
      name: "AudioSidecarError",
      message: "boom",
    });

    expect(harness.events).toHaveLength(1);
    expect(harness.errors).toHaveLength(1);

    await harness.dispose();
    api.emitEvent({
      event: "playbackStateChanged",
      payload: {
        state: "playing",
      },
    });

    expect(harness.events).toHaveLength(1);
    expect(api.stop).toHaveBeenCalled();
  });
});

function createTarget(api: AudioSidecarApi): Window {
  return {
    api: {
      audioSidecar: api,
    },
  } as Window;
}

function createFakeAudioSidecarApi(options: { available?: boolean } = {}) {
  const eventListeners = new Set<Parameters<AudioSidecarApi["onEvent"]>[0]>();
  const errorListeners = new Set<Parameters<AudioSidecarApi["onError"]>[0]>();

  return {
    isAvailable: vi.fn().mockResolvedValue(options.available ?? true),
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn().mockResolvedValue(undefined),
    load: vi.fn().mockResolvedValue(undefined),
    play: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn().mockResolvedValue(undefined),
    stopPlayback: vi.fn().mockResolvedValue(undefined),
    seek: vi.fn().mockResolvedValue(undefined),
    onEvent: vi.fn((listener) => {
      eventListeners.add(listener);
      return () => eventListeners.delete(listener);
    }),
    onError: vi.fn((listener) => {
      errorListeners.add(listener);
      return () => errorListeners.delete(listener);
    }),
    emitEvent: (event) => {
      for (const listener of eventListeners) listener(event);
    },
    emitError: (error) => {
      for (const listener of errorListeners) listener(error);
    },
  } satisfies AudioSidecarApi & {
    emitEvent: Parameters<AudioSidecarApi["onEvent"]>[0];
    emitError: Parameters<AudioSidecarApi["onError"]>[0];
  };
}
