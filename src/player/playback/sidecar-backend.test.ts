import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AudioSidecarBridgeErrorPayload,
  AudioSidecarEventEnvelope,
} from "../../../electron/main/core/audioSidecarBridge";
import {
  AUDIO_SIDECAR_PLAYBACK_FLAG,
  createUrlPlaybackSource,
  ElectronAudioSidecarPlaybackBackend,
  getElectronAudioSidecarAvailability,
  isAudioSidecarPlaybackEnabled,
  type PlaybackBackendEvent,
  type PlaybackBackendListener,
} from ".";

vi.mock("@/utils/desktop", () => ({
  hasElectronBridge: vi.fn(),
  isDesktop: vi.fn(),
}));

import { hasElectronBridge, isDesktop } from "@/utils/desktop";

const mockHasElectronBridge = vi.mocked(hasElectronBridge);
const mockIsDesktop = vi.mocked(isDesktop);

describe("ElectronAudioSidecarPlaybackBackend", () => {
  beforeEach(() => {
    vi.unstubAllEnvs();
  });

  it("delegates MVP controls to window.api.audioSidecar", async () => {
    const api = createFakeAudioSidecarApi();
    const backend = new ElectronAudioSidecarPlaybackBackend(api);
    const source = createUrlPlaybackSource("https://server/song.mp3", {
      songId: "song-1",
    });

    await backend.load(
      source,
      {
        title: "Song",
        artist: "Artist",
        album: "Album",
        duration: 120,
        artworkUrl: "https://server/art.jpg",
      },
      { autoplay: true },
    );
    await backend.play();
    await backend.pause();
    await backend.stop();
    await backend.seek(-10);
    await backend.setRepeatMode("all");
    await backend.setShuffle(true);
    await backend.updateMetadata({ title: "Updated" });
    await backend.preload(createUrlPlaybackSource("https://server/next.mp3"));

    expect(api.load).toHaveBeenCalledWith({
      source: {
        kind: "stream",
        url: "https://server/song.mp3",
        songId: "song-1",
      },
      metadata: {
        title: "Song",
        artist: "Artist",
        album: "Album",
        duration: 120,
        artworkUrl: "https://server/art.jpg",
      },
      requestId: "sidecar-audio-1",
      autoplay: true,
    });
    expect(api.play).toHaveBeenCalledTimes(1);
    expect(api.pause).toHaveBeenCalledTimes(1);
    expect(api.stopPlayback).toHaveBeenCalledTimes(1);
    expect(api.seek).toHaveBeenCalledWith({ position: 0 });
    expect(api.stop).not.toHaveBeenCalled();
  });

  it("maps sidecar events to playback backend events", async () => {
    const api = createFakeAudioSidecarApi();
    const backend = new ElectronAudioSidecarPlaybackBackend(api);
    const listeners = makePlaybackListeners();

    backend.subscribe("progress", listeners.progress);
    backend.subscribe("duration", listeners.duration);
    backend.subscribe("buffering", listeners.buffering);
    backend.subscribe("play", listeners.play);
    backend.subscribe("pause", listeners.pause);
    backend.subscribe("ended", listeners.ended);
    backend.subscribe("error", listeners.error);

    api.emitEvent({
      event: "progress",
      payload: {
        currentTime: 32,
        duration: 180,
        bufferedTime: 90,
      },
    });
    api.emitEvent({
      event: "durationChanged",
      payload: { duration: 181 },
    });
    api.emitEvent({
      event: "bufferingChanged",
      payload: { isBuffering: true },
    });
    api.emitEvent({
      event: "playbackStateChanged",
      payload: { state: "playing" },
    });
    api.emitEvent({
      event: "playbackStateChanged",
      payload: { state: "paused" },
    });
    api.emitEvent({ event: "ended", payload: { reason: "finished" } });
    api.emitEvent({
      event: "error",
      payload: { code: "network", message: "Sidecar stream failed" },
    });

    expect(listeners.progress).toHaveBeenCalledWith({
      currentTime: 32,
      duration: 180,
      bufferedTime: 90,
    });
    expect(listeners.duration).toHaveBeenCalledWith({ duration: 181 });
    expect(listeners.buffering).toHaveBeenCalledWith({ isBuffering: true });
    expect(listeners.play).toHaveBeenCalledTimes(1);
    expect(listeners.pause).toHaveBeenCalledTimes(1);
    expect(listeners.ended).toHaveBeenCalledTimes(1);
    expect(listeners.error).toHaveBeenCalledWith({
      error: {
        code: "network",
        message: "Sidecar stream failed",
      },
      code: 2,
      kind: "network",
      message: "Sidecar stream failed",
      nativeCode: "network",
    });
  });

  it("ignores stale sidecar events from previous load requests", async () => {
    const api = createFakeAudioSidecarApi();
    const backend = new ElectronAudioSidecarPlaybackBackend(api);
    const listeners = makePlaybackListeners();

    backend.subscribe("progress", listeners.progress);
    backend.subscribe("play", listeners.play);

    await backend.load(createUrlPlaybackSource("https://server/old.mp3"));
    await backend.load(createUrlPlaybackSource("https://server/new.mp3"));

    api.emitEvent({
      event: "progress",
      payload: {
        requestId: "sidecar-audio-1",
        currentTime: 99,
        duration: 180,
      },
    });
    api.emitEvent({
      event: "playbackStateChanged",
      payload: {
        requestId: "sidecar-audio-1",
        state: "playing",
      },
    });
    api.emitEvent({
      event: "progress",
      payload: {
        requestId: "sidecar-audio-2",
        currentTime: 12,
        duration: 180,
      },
    });

    expect(listeners.progress).toHaveBeenCalledTimes(1);
    expect(listeners.progress).toHaveBeenCalledWith({
      currentTime: 12,
      duration: 180,
      bufferedTime: 12,
    });
    expect(listeners.play).not.toHaveBeenCalled();
  });

  it("removes listeners and stops the sidecar process on dispose", () => {
    const api = createFakeAudioSidecarApi();
    const backend = new ElectronAudioSidecarPlaybackBackend(api);
    const progress = vi.fn();

    backend.subscribe("progress", progress);
    backend.dispose();

    api.emitEvent({
      event: "progress",
      payload: { currentTime: 1, duration: 2 },
    });

    expect(progress).not.toHaveBeenCalled();
    expect(api.stop).toHaveBeenCalledTimes(1);
    expect(() => backend.play()).toThrow("Playback backend has been disposed");
  });
});

describe("Electron sidecar playback flag", () => {
  beforeEach(() => {
    vi.unstubAllEnvs();
    mockHasElectronBridge.mockReset();
    mockIsDesktop.mockReset();
    mockHasElectronBridge.mockReturnValue(false);
    mockIsDesktop.mockReturnValue(false);
  });

  it("is disabled by default", () => {
    expect(isAudioSidecarPlaybackEnabled(createTarget())).toBe(false);
    expect(getElectronAudioSidecarAvailability(createTarget())).toEqual({
      available: false,
      reason: "disabled",
    });
  });

  it("can be enabled through a Vite env flag", () => {
    vi.stubEnv("VITE_AONSOKU_AUDIO_SIDECAR", "1");

    expect(isAudioSidecarPlaybackEnabled(createTarget())).toBe(true);
  });

  it("can be enabled through localStorage for runtime smoke testing", () => {
    const target = createTarget({
      [AUDIO_SIDECAR_PLAYBACK_FLAG]: "1",
    });

    expect(isAudioSidecarPlaybackEnabled(target)).toBe(true);
  });

  it("reports the Electron preload sidecar API when the flag and bridge exist", () => {
    vi.stubEnv("VITE_AONSOKU_AUDIO_SIDECAR", "1");
    mockIsDesktop.mockReturnValue(true);
    mockHasElectronBridge.mockReturnValue(true);
    const api = createFakeAudioSidecarApi();

    expect(
      getElectronAudioSidecarAvailability(createTarget({}, api)),
    ).toEqual({
      available: true,
      api,
    });
  });
});

function createFakeAudioSidecarApi() {
  const eventListeners = new Set<(event: AudioSidecarEventEnvelope) => void>();
  const errorListeners = new Set<
    (error: AudioSidecarBridgeErrorPayload) => void
  >();

  return {
    isAvailable: vi.fn(async () => true),
    start: vi.fn(async () => {}),
    stop: vi.fn(async () => {}),
    load: vi.fn(async () => {}),
    play: vi.fn(async () => {}),
    pause: vi.fn(async () => {}),
    stopPlayback: vi.fn(async () => {}),
    seek: vi.fn(async () => {}),
    onEvent: vi.fn((listener) => {
      eventListeners.add(listener);
      return () => eventListeners.delete(listener);
    }),
    onError: vi.fn((listener) => {
      errorListeners.add(listener);
      return () => errorListeners.delete(listener);
    }),
    emitEvent: (event: AudioSidecarEventEnvelope) => {
      for (const listener of eventListeners) listener(event);
    },
    emitError: (error: AudioSidecarBridgeErrorPayload) => {
      for (const listener of errorListeners) listener(error);
    },
  } satisfies Window["api"]["audioSidecar"] & {
    emitEvent: (event: AudioSidecarEventEnvelope) => void;
    emitError: (error: AudioSidecarBridgeErrorPayload) => void;
  };
}

function createTarget(
  localStorageValues: Record<string, string> = {},
  api = createFakeAudioSidecarApi(),
) {
  return {
    api: {
      audioSidecar: api,
    },
    localStorage: {
      getItem: (key: string) => localStorageValues[key] ?? null,
    },
  } as Pick<Window, "api" | "localStorage">;
}

function makePlaybackListeners() {
  return {
    progress: vi.fn() as PlaybackBackendListener<"progress">,
    duration: vi.fn() as PlaybackBackendListener<"duration">,
    buffering: vi.fn() as PlaybackBackendListener<"buffering">,
    ended: vi.fn() as PlaybackBackendListener<"ended">,
    play: vi.fn() as PlaybackBackendListener<"play">,
    pause: vi.fn() as PlaybackBackendListener<"pause">,
    error: vi.fn() as PlaybackBackendListener<"error">,
    remoteCommand: vi.fn() as PlaybackBackendListener<"remoteCommand">,
  } satisfies {
    [TEvent in PlaybackBackendEvent]: PlaybackBackendListener<TEvent>;
  };
}
