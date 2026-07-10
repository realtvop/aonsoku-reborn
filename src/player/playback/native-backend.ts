import type { PluginListenerHandle } from "@capacitor/core";
import type {
  NativeAudioEventName,
  NativeAudioErrorEvent,
  NativeAudioEvents,
  NativeAudioMetadata,
  NativeAudioPlugin,
  NativeAudioSource,
} from "@/native/audio";
import { getRuntime } from "@/utils/capabilities";
import { nativePlaybackErrorKind, playbackErrorCodeFromKind } from "./errors";
import {
  type PlaybackBackend,
  type PlaybackBackendEvent,
  type PlaybackBackendEvents,
  type PlaybackBackendListener,
  type PlaybackErrorEvent,
  type PlaybackMetadata,
  type PlaybackRepeatMode,
  type PlaybackSource,
  type UnsubscribePlaybackEvent,
} from "./types";

type ListenerMap = {
  [TEvent in PlaybackBackendEvent]: Set<PlaybackBackendListener<TEvent>>;
};

export class NativeAudioPlaybackBackend implements PlaybackBackend {
  readonly #plugin: NativeAudioPlugin;
  readonly #listeners: ListenerMap;
  readonly #nativeListenerHandles: Array<Promise<PluginListenerHandle | null>> =
    [];
  #loadSequence = 0;
  #activeRequestId: string | null = null;
  #pendingManualRequest = false;
  #disposed = false;

  constructor(plugin: NativeAudioPlugin) {
    this.#plugin = plugin;
    this.#listeners = {
      progress: new Set(),
      duration: new Set(),
      buffering: new Set(),
      ended: new Set(),
      play: new Set(),
      pause: new Set(),
      error: new Set(),
      remoteCommand: new Set(),
    };
    this.#wireNativeEvents();
  }

  load(
    source: PlaybackSource,
    metadata?: PlaybackMetadata,
    options?: { autoplay?: boolean },
  ) {
    this.#assertActive();
    const requestId = this.#nextRequestId();

    return this.#plugin.load({
      source: toNativeAudioSource(source),
      metadata: metadata ? toNativeAudioMetadata(metadata) : undefined,
      requestId,
      autoplay: options?.autoplay,
    });
  }

  play() {
    this.#assertActive();
    return this.#plugin.play();
  }

  pause() {
    this.#assertActive();
    return this.#plugin.pause();
  }

  stop() {
    this.#assertActive();
    return this.#plugin.stop();
  }

  seek(seconds: number) {
    this.#assertActive();
    return this.#plugin.seek({ position: Math.max(0, seconds) });
  }

  setLoop(enabled: boolean) {
    return this.setRepeatMode(enabled ? "one" : "off");
  }

  setRepeatMode(mode: PlaybackRepeatMode) {
    this.#assertActive();
    return this.#plugin.setRepeatMode({ mode });
  }

  setShuffle(enabled: boolean) {
    this.#assertActive();
    return this.#plugin.setShuffle({ enabled });
  }

  skipToNext() {
    this.#assertActive();
    return this.#plugin.skipToNext();
  }

  skipToPrevious() {
    this.#assertActive();
    return this.#plugin.skipToPrevious();
  }

  setVolume(value: number) {
    this.#assertActive();
    if (getRuntime() !== "electron") return Promise.resolve();

    return this.#plugin
      .setSystemVolume({ value: clampUnitVolume(value) })
      .then(() => undefined)
      .catch(() => undefined);
  }

  updateMetadata(metadata: PlaybackMetadata) {
    this.#assertActive();
    return this.#plugin.updateMetadata(toNativeAudioMetadata(metadata));
  }

  preload(source: PlaybackSource) {
    this.#assertActive();
    return this.#plugin.preload({ source: toNativeAudioSource(source) });
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#activeRequestId = null;
    this.#pendingManualRequest = false;

    for (const handlePromise of this.#nativeListenerHandles) {
      handlePromise.then((handle) => handle?.remove()).catch(() => {});
    }
    this.#nativeListenerHandles.length = 0;

    for (const listeners of Object.values(this.#listeners)) {
      listeners.clear();
    }
  }

  subscribe<TEvent extends PlaybackBackendEvent>(
    event: TEvent,
    listener: PlaybackBackendListener<TEvent>,
  ): UnsubscribePlaybackEvent {
    this.#listeners[event].add(listener);

    return () => {
      this.#listeners[event].delete(listener);
    };
  }

  #wireNativeEvents() {
    this.#addNativeListener("progress", (event) => {
      if (this.#isStaleNativeEvent(event)) return;
      this.#emit("progress", {
        currentTime: event.currentTime,
        duration: event.duration,
        bufferedTime: event.bufferedTime ?? event.currentTime,
      });
    });
    this.#addNativeListener("durationChanged", (event) => {
      if (this.#isStaleNativeEvent(event)) return;
      this.#emit("duration", { duration: event.duration });
    });
    this.#addNativeListener("bufferingChanged", (event) => {
      if (this.#isStaleNativeEvent(event)) return;
      this.#emit("buffering", { isBuffering: event.isBuffering });
    });
    this.#addNativeListener("ended", (event) => {
      if (this.#isStaleNativeEvent(event)) return;
      this.#emit("ended", undefined);
    });
    this.#addNativeListener("error", (event) => {
      if (this.#isStaleNativeEvent(event)) return;
      this.#emit("error", toPlaybackErrorEvent(event));
    });
    this.#addNativeListener("playbackStateChanged", (event) => {
      if (this.#isStaleNativeEvent(event)) return;
      if (event.state === "playing") {
        this.#emit("play", undefined);
      } else if (
        event.state === "paused" ||
        event.state === "stopped" ||
        event.state === "ended"
      ) {
        this.#emit("pause", undefined);
      }
    });
    this.#addNativeListener("remoteCommand", (event) => {
      if (this.#isStaleNativeEvent(event)) return;
      this.#emit("remoteCommand", {
        command: event.command,
        position: event.position,
      });
    });
  }

  #addNativeListener<TEvent extends NativeAudioEventName>(
    event: TEvent,
    listener: (payload: NativeAudioEvents[TEvent]) => void,
  ) {
    const handlePromise = this.#plugin
      .addListener(event, listener)
      .then((handle) => handle)
      .catch((error: unknown) => {
        this.#emit("error", toPlaybackErrorEvent(error));
        return null;
      });
    this.#nativeListenerHandles.push(handlePromise);
  }

  #emit<TEvent extends PlaybackBackendEvent>(
    event: TEvent,
    payload: PlaybackBackendEvents[TEvent],
  ) {
    if (this.#disposed) return;

    for (const listener of this.#listeners[event]) {
      listener(payload);
    }
  }

  #assertActive() {
    if (this.#disposed) {
      throw new Error("Playback backend has been disposed");
    }
  }

  #nextRequestId() {
    const requestId = `native-audio-${++this.#loadSequence}`;
    this.#activeRequestId = requestId;
    this.#pendingManualRequest = true;

    return requestId;
  }

  #isStaleNativeEvent(event: { requestId?: string | null }) {
    if (event.requestId === undefined || event.requestId === null) {
      return false;
    }

    if (this.#activeRequestId === null) {
      this.#activeRequestId = event.requestId;
      this.#pendingManualRequest = false;
      return false;
    }

    if (event.requestId === this.#activeRequestId) {
      this.#pendingManualRequest = false;
      return false;
    }

    if (
      !this.#pendingManualRequest &&
      event.requestId.startsWith("desktop-native-queue-")
    ) {
      this.#activeRequestId = event.requestId;
      return false;
    }

    return true;
  }
}

export function createNativeAudioPlaybackBackend(plugin: NativeAudioPlugin) {
  return new NativeAudioPlaybackBackend(plugin);
}

export function toNativeAudioMetadata(
  metadata: PlaybackMetadata,
): NativeAudioMetadata {
  return {
    title: metadata.title,
    artist: metadata.artist,
    album: metadata.album,
    duration: metadata.duration,
    artworkUrl: metadata.artworkUrl,
  };
}

export function toNativeAudioSource(source: PlaybackSource): NativeAudioSource {
  switch (source.kind) {
    case "stream":
      return {
        kind: "stream",
        url: source.url,
        songId: source.songId,
      };
    case "blob":
      return {
        kind: "blob",
        url: source.url,
        songId: source.songId,
      };
    case "native-file":
      return {
        kind: "native-file",
        uri: source.uri,
        songId: source.songId,
      };
    case "radio":
      return {
        kind: "radio",
        url: source.url,
        radioId: source.radioId,
      };
  }
}

function toPlaybackErrorEvent(
  error: NativeAudioErrorEvent | unknown,
): PlaybackErrorEvent {
  if (isNativeAudioErrorEvent(error)) {
    const kind = nativePlaybackErrorKind(error.code);

    return {
      error,
      code: playbackErrorCodeFromKind(kind) ?? error.code,
      kind,
      message: error.message,
      nativeCode: error.code,
    };
  }

  if (error instanceof Error) {
    return {
      error,
      kind: "unknown",
      message: error.message,
    };
  }

  return {
    error,
    kind: "unknown",
    message: "Native audio listener failed",
  };
}

function isNativeAudioErrorEvent(
  error: unknown,
): error is NativeAudioErrorEvent {
  return (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof (error as { message?: unknown }).message === "string"
  );
}

function clampUnitVolume(value: number): number {
  if (!Number.isFinite(value)) return 1;
  return Math.max(0, Math.min(1, value));
}
