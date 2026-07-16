import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NativeAudioEvents, NativeAudioPlugin } from "@/native/audio";
import {
  createUrlPlaybackSource,
  NativeAudioPlaybackBackend,
  toNativeAudioMetadata,
  toNativeAudioSource,
  type PlaybackBackendEvent,
  type PlaybackBackendListener,
} from ".";

const mocks = vi.hoisted(() => ({
  getRuntime: vi.fn(() => "capacitor-ios"),
}));

vi.mock("@/utils/capabilities", () => ({
  getRuntime: mocks.getRuntime,
}));

type ListenerMap = {
  [TEvent in keyof NativeAudioEvents]?: Array<
    (event: NativeAudioEvents[TEvent]) => void
  >;
};

function createPlugin() {
  const listeners: ListenerMap = {};
  const plugin: NativeAudioPlugin = {
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
    setSystemVolume: vi.fn(async () => ({ volume: 1 })),
    updateMetadata: vi.fn(async () => {}),
    preload: vi.fn(async () => {}),
    clear: vi.fn(async () => {}),
    storeAudioFile: vi.fn(async () => ({
      songId: "song-1",
      uri: "file:///native-cache/song-1.mp3",
    })),
    resolveAudioFile: vi.fn(async () => ({ file: null })),
    getAudioFileSize: vi.fn(async () => ({ sizeBytes: null })),
    deleteAudioFile: vi.fn(async () => ({ deleted: false })),
    clearAudioFiles: vi.fn(async () => ({ deletedCount: 0 })),
    addListener: vi.fn(async (eventName, listener) => {
      listeners[eventName] ??= [];
      listeners[eventName]?.push(listener);

      return {
        remove: vi.fn(async () => {
          listeners[eventName] = listeners[eventName]?.filter(
            (item) => item !== listener,
          );
        }),
      };
    }),
    removeAllListeners: vi.fn(async () => {}),
  };

  function emit<TEvent extends keyof NativeAudioEvents>(
    eventName: TEvent,
    event: NativeAudioEvents[TEvent],
  ) {
    for (const listener of listeners[eventName] ?? []) {
      listener(event);
    }
  }

  return { plugin, emit };
}

describe("NativeAudioPlaybackBackend", () => {
  beforeEach(() => {
    mocks.getRuntime.mockReturnValue("capacitor-ios");
  });

  it("maps playback sources to native audio sources", () => {
    expect(
      toNativeAudioSource(
        createUrlPlaybackSource("https://server/rest/stream?id=song-1", {
          songId: "song-1",
        }),
      ),
    ).toEqual({
      kind: "stream",
      url: "https://server/rest/stream?id=song-1",
      songId: "song-1",
    });
    expect(
      toNativeAudioSource({
        kind: "native-file",
        uri: "file:///Library/Caches/song.flac",
        songId: "song-2",
      }),
    ).toEqual({
      kind: "native-file",
      uri: "file:///Library/Caches/song.flac",
      songId: "song-2",
    });
    expect(
      toNativeAudioSource(
        createUrlPlaybackSource("https://radio.example/stream", {
          kind: "radio",
          radioId: "radio-1",
        }),
      ),
    ).toEqual({
      kind: "radio",
      url: "https://radio.example/stream",
      radioId: "radio-1",
    });
  });

  it("maps playback metadata to native audio metadata", () => {
    expect(
      toNativeAudioMetadata({
        title: "Song",
        artist: "Artist",
        album: "Album",
        duration: 123,
        artworkUrl: "https://server/art.jpg",
      }),
    ).toEqual({
      title: "Song",
      artist: "Artist",
      album: "Album",
      duration: 123,
      artworkUrl: "https://server/art.jpg",
    });
  });

  it("delegates backend controls to the native plugin", async () => {
    const { plugin } = createPlugin();
    const backend = new NativeAudioPlaybackBackend(plugin);
    const source = createUrlPlaybackSource("https://server/song.mp3", {
      songId: "song-1",
    });
    const preloadSource = createUrlPlaybackSource("https://server/next.mp3", {
      songId: "song-2",
    });
    const metadata = {
      title: "Song",
      artist: "Artist",
      album: "Album",
      duration: 120,
      artworkUrl: "https://server/art.jpg",
    };

    await backend.load(source, metadata);
    await backend.play();
    await backend.pause();
    await backend.stop();
    await backend.seek(-12);
    await backend.setLoop(true);
    await backend.setRepeatMode("all");
    await backend.setShuffle(true);
    await backend.skipToNext();
    await backend.skipToPrevious();
    await backend.setVolume(0.5);
    await backend.updateMetadata({ title: "Updated Song" });
    await backend.preload(preloadSource);

    expect(plugin.load).toHaveBeenCalledWith({
      source: {
        kind: "stream",
        url: "https://server/song.mp3",
        songId: "song-1",
      },
      metadata,
      requestId: "native-audio-1",
    });
    expect(plugin.play).toHaveBeenCalledTimes(1);
    expect(plugin.pause).toHaveBeenCalledTimes(1);
    expect(plugin.stop).toHaveBeenCalledTimes(1);
    expect(plugin.seek).toHaveBeenCalledWith({ position: 0 });
    expect(plugin.setRepeatMode).toHaveBeenCalledWith({ mode: "one" });
    expect(plugin.setRepeatMode).toHaveBeenCalledWith({ mode: "all" });
    expect(plugin.setShuffle).toHaveBeenCalledWith({ enabled: true });
    expect(plugin.skipToNext).toHaveBeenCalledTimes(1);
    expect(plugin.skipToPrevious).toHaveBeenCalledTimes(1);
    expect(plugin.setSystemVolume).not.toHaveBeenCalled();
    expect(plugin.updateMetadata).toHaveBeenCalledWith({
      title: "Updated Song",
      artist: undefined,
      album: undefined,
      duration: undefined,
      artworkUrl: undefined,
    });
    expect(plugin.preload).toHaveBeenCalledWith({
      source: {
        kind: "stream",
        url: "https://server/next.mp3",
        songId: "song-2",
      },
    });
  });

  it("routes Electron native backend volume to the desktop player bridge", async () => {
    mocks.getRuntime.mockReturnValue("electron");
    const { plugin } = createPlugin();
    const backend = new NativeAudioPlaybackBackend(plugin);

    await backend.setVolume(1.25);
    await backend.setVolume(-1);
    await backend.setVolume(Number.NaN);

    expect(plugin.setSystemVolume).toHaveBeenCalledWith({ value: 1 });
    expect(plugin.setSystemVolume).toHaveBeenCalledWith({ value: 0 });
    expect(plugin.setSystemVolume).toHaveBeenCalledTimes(3);

    backend.dispose();
  });

  it("loads radio streams with their native radio metadata", async () => {
    const { plugin } = createPlugin();
    const backend = new NativeAudioPlaybackBackend(plugin);

    await backend.load(
      createUrlPlaybackSource("https://radio.example/stream", {
        kind: "radio",
        radioId: "radio-1",
      }),
    );

    expect(plugin.load).toHaveBeenCalledWith({
      source: {
        kind: "radio",
        url: "https://radio.example/stream",
        radioId: "radio-1",
      },
      requestId: "native-audio-1",
    });
  });

  it("maps native events to playback backend events", async () => {
    const { plugin, emit } = createPlugin();
    const backend = new NativeAudioPlaybackBackend(plugin);
    const listeners = makePlaybackListeners();

    backend.subscribe("progress", listeners.progress);
    backend.subscribe("duration", listeners.duration);
    backend.subscribe("buffering", listeners.buffering);
    backend.subscribe("play", listeners.play);
    backend.subscribe("pause", listeners.pause);
    backend.subscribe("ended", listeners.ended);
    backend.subscribe("error", listeners.error);
    backend.subscribe("remoteCommand", listeners.remoteCommand);

    await Promise.resolve();

    emit("progress", {
      currentTime: 32,
      duration: 180,
      bufferedTime: 90,
    });
    emit("durationChanged", { duration: 181 });
    emit("bufferingChanged", { isBuffering: true });
    emit("playbackStateChanged", { state: "playing" });
    emit("playbackStateChanged", { state: "paused" });
    emit("ended", { reason: "finished" });
    emit("error", { code: "network", message: "Native stream failed" });
    emit("remoteCommand", { command: "seek", position: 42 });

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
        message: "Native stream failed",
      },
      code: 2,
      kind: "network",
      message: "Native stream failed",
      nativeCode: "network",
    });
    expect(listeners.remoteCommand).toHaveBeenCalledWith({
      command: "seek",
      position: 42,
    });
  });

  it("ignores stale native events from previous load requests", async () => {
    const { plugin, emit } = createPlugin();
    const backend = new NativeAudioPlaybackBackend(plugin);
    const listeners = makePlaybackListeners();

    backend.subscribe("progress", listeners.progress);
    backend.subscribe("play", listeners.play);
    backend.subscribe("ended", listeners.ended);
    backend.subscribe("error", listeners.error);

    await backend.load(createUrlPlaybackSource("https://server/old.mp3"));
    await backend.load(createUrlPlaybackSource("https://server/new.mp3"));

    emit("progress", {
      requestId: "native-audio-1",
      currentTime: 91,
      duration: 180,
    });
    emit("playbackStateChanged", {
      requestId: "native-audio-1",
      state: "playing",
    });
    emit("ended", {
      requestId: "native-audio-1",
      reason: "finished",
    });
    emit("error", {
      requestId: "native-audio-1",
      code: "network",
      message: "Old source failed late",
    });

    emit("progress", {
      requestId: "native-audio-2",
      currentTime: 12,
      duration: 180,
    });
    emit("playbackStateChanged", {
      requestId: "native-audio-2",
      state: "playing",
    });

    expect(listeners.progress).toHaveBeenCalledTimes(1);
    expect(listeners.progress).toHaveBeenCalledWith({
      currentTime: 12,
      duration: 180,
      bufferedTime: 12,
    });
    expect(listeners.play).toHaveBeenCalledTimes(1);
    expect(listeners.ended).not.toHaveBeenCalled();
    expect(listeners.error).not.toHaveBeenCalled();
  });

  it("accepts desktop-native-queue events after active manual load finishes loading, but rejects them if manual load is pending", async () => {
    const { plugin, emit } = createPlugin();
    const backend = new NativeAudioPlaybackBackend(plugin);
    const listeners = makePlaybackListeners();

    backend.subscribe("progress", listeners.progress);

    // 1. Manually load native-audio-1
    await backend.load(createUrlPlaybackSource("https://server/song1.mp3"));

    // 2. While manual load is pending, a desktop-native-queue event arrives (should be ignored)
    emit("progress", {
      requestId: "desktop-native-queue-1",
      currentTime: 10,
      duration: 100,
    });
    expect(listeners.progress).not.toHaveBeenCalled();

    // 3. Emit a progress event for native-audio-1 (clears pendingManualRequest)
    emit("progress", {
      requestId: "native-audio-1",
      currentTime: 1,
      duration: 100,
    });
    expect(listeners.progress).toHaveBeenCalledTimes(1);
    expect(listeners.progress).toHaveBeenLastCalledWith({
      currentTime: 1,
      duration: 100,
      bufferedTime: 1,
    });

    // 4. Now the song transitions natively, emitting a desktop-native-queue-1 event (should be accepted)
    emit("progress", {
      requestId: "desktop-native-queue-1",
      currentTime: 2,
      duration: 100,
    });
    expect(listeners.progress).toHaveBeenCalledTimes(2);
    expect(listeners.progress).toHaveBeenLastCalledWith({
      currentTime: 2,
      duration: 100,
      bufferedTime: 2,
    });

    // 5. Subsequent events for desktop-native-queue-1 are accepted
    emit("progress", {
      requestId: "desktop-native-queue-1",
      currentTime: 3,
      duration: 100,
    });
    expect(listeners.progress).toHaveBeenCalledTimes(3);

    // 6. User manually triggers another load (native-audio-2)
    await backend.load(createUrlPlaybackSource("https://server/song2.mp3"));

    // 7. A late event from desktop-native-queue-1 arrives (should be ignored since native-audio-2 is pending)
    emit("progress", {
      requestId: "desktop-native-queue-1",
      currentTime: 4,
      duration: 100,
    });
    expect(listeners.progress).toHaveBeenCalledTimes(3); // count remains 3
  });

  it("removes native listeners on dispose without clearing plugin state", async () => {
    const { plugin, emit } = createPlugin();
    const backend = new NativeAudioPlaybackBackend(plugin);
    const progress = vi.fn();

    backend.subscribe("progress", progress);
    await Promise.resolve();
    backend.dispose();
    await Promise.resolve();

    emit("progress", { currentTime: 1, duration: 2 });

    expect(progress).not.toHaveBeenCalled();
    expect(plugin.clear).not.toHaveBeenCalled();
    expect(() => backend.play()).toThrow("Playback backend has been disposed");
  });
});

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
