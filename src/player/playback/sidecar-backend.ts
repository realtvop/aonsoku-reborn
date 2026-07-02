import type {
  AudioSidecarBridgeErrorPayload,
  AudioSidecarEventEnvelope,
} from "../../../electron/main/core/audioSidecarBridge";
import { hasElectronBridge, isDesktop } from "@/utils/desktop";
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
import { toNativeAudioMetadata, toNativeAudioSource } from "./native-backend";

export const AUDIO_SIDECAR_PLAYBACK_FLAG =
  "aonsoku.audioSidecar.playback.enabled";

type AudioSidecarApi = Window["api"]["audioSidecar"];

type ListenerMap = {
  [TEvent in PlaybackBackendEvent]: Set<PlaybackBackendListener<TEvent>>;
};

export type ElectronAudioSidecarAvailability =
  | {
      available: true;
      api: AudioSidecarApi;
    }
  | {
      available: false;
      reason: "disabled" | "unsupported-platform" | "missing-bridge";
    };

export class ElectronAudioSidecarPlaybackBackend implements PlaybackBackend {
  readonly #api: AudioSidecarApi;
  readonly #listeners: ListenerMap;
  readonly #removeEventListener: () => void;
  readonly #removeErrorListener: () => void;
  #loadSequence = 0;
  #activeRequestId: string | null = null;
  #disposed = false;

  constructor(api: AudioSidecarApi) {
    this.#api = api;
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
    this.#removeEventListener = api.onEvent((envelope) => {
      this.#handleEvent(envelope);
    });
    this.#removeErrorListener = api.onError((error) => {
      this.#emit("error", toPlaybackErrorEvent(error));
    });
  }

  load(
    source: PlaybackSource,
    metadata?: PlaybackMetadata,
    options?: { autoplay?: boolean },
  ) {
    this.#assertActive();
    const requestId = this.#nextRequestId();

    return this.#api.load({
      source: toNativeAudioSource(source),
      metadata: metadata ? toNativeAudioMetadata(metadata) : undefined,
      requestId,
      autoplay: options?.autoplay,
    });
  }

  play() {
    this.#assertActive();
    return this.#api.play();
  }

  pause() {
    this.#assertActive();
    return this.#api.pause();
  }

  stop() {
    this.#assertActive();
    return this.#api.stopPlayback();
  }

  seek(seconds: number) {
    this.#assertActive();
    return this.#api.seek({ position: Math.max(0, seconds) });
  }

  setLoop(_enabled: boolean) {
    this.#assertActive();
    return Promise.resolve();
  }

  setRepeatMode(_mode: PlaybackRepeatMode) {
    this.#assertActive();
    return Promise.resolve();
  }

  setShuffle(_enabled: boolean) {
    this.#assertActive();
    return Promise.resolve();
  }

  skipToNext() {
    this.#assertActive();
    return Promise.resolve();
  }

  skipToPrevious() {
    this.#assertActive();
    return Promise.resolve();
  }

  setVolume(_value: number) {
    this.#assertActive();
    return Promise.resolve();
  }

  updateMetadata(_metadata: PlaybackMetadata) {
    this.#assertActive();
    return Promise.resolve();
  }

  preload(_source: PlaybackSource) {
    this.#assertActive();
    return Promise.resolve();
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#activeRequestId = null;
    this.#removeEventListener();
    this.#removeErrorListener();
    void this.#api.stop().catch(() => {});

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

  #handleEvent(envelope: AudioSidecarEventEnvelope) {
    if (this.#disposed) return;

    const payload = envelope.payload;
    if (isStaleSidecarEvent(payload, this.#activeRequestId)) return;

    switch (envelope.event) {
      case "progress":
        this.#emit("progress", {
          currentTime: payload.currentTime,
          duration: payload.duration,
          bufferedTime: payload.bufferedTime ?? payload.currentTime,
        });
        break;
      case "durationChanged":
        this.#emit("duration", { duration: payload.duration });
        break;
      case "bufferingChanged":
        this.#emit("buffering", { isBuffering: payload.isBuffering });
        break;
      case "ended":
        this.#emit("ended", undefined);
        break;
      case "error":
        this.#emit("error", toPlaybackErrorEvent(payload));
        break;
      case "playbackStateChanged":
        if (payload.state === "playing") {
          this.#emit("play", undefined);
        } else if (
          payload.state === "paused" ||
          payload.state === "stopped" ||
          payload.state === "ended"
        ) {
          this.#emit("pause", undefined);
        }
        break;
    }
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
    const requestId = `sidecar-audio-${++this.#loadSequence}`;
    this.#activeRequestId = requestId;

    return requestId;
  }
}

export function createElectronAudioSidecarPlaybackBackend(
  api: AudioSidecarApi,
) {
  return new ElectronAudioSidecarPlaybackBackend(api);
}

export function getElectronAudioSidecarAvailability(
  target: Pick<Window, "api" | "localStorage"> | undefined = typeof window ===
  "undefined"
    ? undefined
    : window,
): ElectronAudioSidecarAvailability {
  if (!isAudioSidecarPlaybackEnabled(target)) {
    return { available: false, reason: "disabled" };
  }

  if (!isDesktop()) {
    return { available: false, reason: "unsupported-platform" };
  }

  if (!hasElectronBridge() || !target?.api?.audioSidecar) {
    return { available: false, reason: "missing-bridge" };
  }

  return {
    available: true,
    api: target.api.audioSidecar,
  };
}

export function isAudioSidecarPlaybackEnabled(
  target: Pick<Window, "localStorage"> | undefined = typeof window ===
  "undefined"
    ? undefined
    : window,
) {
  if (!import.meta.env.DEV) return false;

  if (import.meta.env.VITE_AONSOKU_AUDIO_SIDECAR === "1") {
    return true;
  }

  try {
    return target?.localStorage.getItem(AUDIO_SIDECAR_PLAYBACK_FLAG) === "1";
  } catch {
    return false;
  }
}

function isStaleSidecarEvent(
  event: { requestId?: string | null },
  activeRequestId: string | null,
) {
  return (
    event.requestId !== undefined &&
    event.requestId !== null &&
    activeRequestId !== null &&
    event.requestId !== activeRequestId
  );
}

function toPlaybackErrorEvent(
  error: AudioSidecarBridgeErrorPayload | { code?: string; message: string },
): PlaybackErrorEvent {
  const kind = nativePlaybackErrorKind(error.code);

  return {
    error,
    code: playbackErrorCodeFromKind(kind) ?? error.code,
    kind,
    message: error.message,
    nativeCode: error.code,
  };
}
