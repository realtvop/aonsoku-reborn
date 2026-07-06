import { EventEmitter } from "node:events";
import type { NativeAudioMetadata } from "@aonsoku/audio-contract";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineEvent,
  DesktopAudioEngineEventListener,
  DesktopAudioEngineLoadOptions,
} from "./types";
import type {
  MpvPlayer,
  MpvPlayerEvent,
  MpvPlayerFactory,
  MpvPropertyFormat,
} from "./mpv-player";

interface ObservedMpvProperty {
  name: string;
  format: MpvPropertyFormat;
}

export interface LibMpvAudioEngineOptions {
  playerFactory: MpvPlayerFactory;
}

export class LibMpvAudioEngineError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "LibMpvAudioEngineError";
    this.code = code;
  }
}

const MPV_OPTIONS: Record<string, string> = {
  "audio-display": "no",
  "force-window": "no",
  idle: "yes",
  terminal: "no",
  vid: "no",
};

const MPV_OBSERVED_PROPERTIES: ObservedMpvProperty[] = [
  { name: "time-pos", format: "number" },
  { name: "duration", format: "number" },
  { name: "pause", format: "boolean" },
  { name: "paused-for-cache", format: "boolean" },
  { name: "cache-buffering-state", format: "number" },
];

export class LibMpvAudioEngine implements DesktopAudioEngine {
  readonly #events = new EventEmitter();
  readonly #playerFactory: MpvPlayerFactory;
  #player: MpvPlayer | null = null;
  #unsubscribeFromPlayer: (() => void) | null = null;
  #currentTime = 0;
  #duration = 0;
  #isPaused = true;
  #hasLoadedSource = false;
  #ignoreNextStopEnd = false;
  #destroyed = false;

  constructor(options: LibMpvAudioEngineOptions) {
    this.#playerFactory = options.playerFactory;
  }

  async load(options: DesktopAudioEngineLoadOptions): Promise<void> {
    const player = await this.#ensureStarted();
    this.#ignoreNextStopEnd = this.#hasLoadedSource;
    this.#hasLoadedSource = false;
    this.#currentTime = Math.max(0, options.startTime ?? 0);
    this.#duration = normalizeSeconds(options.metadata?.duration);
    this.#isPaused = options.autoplay !== true;
    this.#emit({ type: "playbackStateChanged", state: "loading" });
    this.#emit({ type: "bufferingChanged", isBuffering: true });

    await this.#setProperty(player, "pause", this.#isPaused);
    await this.updateMetadata(options.metadata ?? {});
    await this.#command(player, ["loadfile", options.source.target, "replace"]);

    if (this.#currentTime > 0) {
      await this.seek(this.#currentTime);
    }
  }

  async play(): Promise<void> {
    const player = await this.#ensureStarted();
    this.#isPaused = false;
    await this.#setProperty(player, "pause", false);
    this.#emit({ type: "playbackStateChanged", state: "playing" });
  }

  async pause(): Promise<void> {
    const player = await this.#ensureStarted();
    this.#isPaused = true;
    await this.#setProperty(player, "pause", true);
    this.#emit({ type: "playbackStateChanged", state: "paused" });
  }

  async stop(): Promise<void> {
    if (!this.#player) return;

    this.#ignoreNextStopEnd = true;
    await this.#command(this.#player, ["stop"]);
    this.#hasLoadedSource = false;
    this.#currentTime = 0;
    this.#emit({ type: "playbackStateChanged", state: "stopped" });
    this.#emit({ type: "ended", reason: "stopped" });
  }

  async seek(position: number): Promise<void> {
    const player = await this.#ensureStarted();
    this.#currentTime = Math.max(0, position);
    await this.#command(player, [
      "seek",
      String(this.#currentTime),
      "absolute",
      "exact",
    ]);
    this.#emitProgress();
  }

  async clear(): Promise<void> {
    if (this.#player) {
      this.#ignoreNextStopEnd = true;
      await this.#command(this.#player, ["stop"]);
    }

    this.#hasLoadedSource = false;
    this.#currentTime = 0;
    this.#duration = 0;
    this.#isPaused = true;
    this.#emit({ type: "bufferingChanged", isBuffering: false });
    this.#emit({ type: "playbackStateChanged", state: "idle" });
  }

  async updateMetadata(metadata: NativeAudioMetadata): Promise<void> {
    if (!this.#player) return;

    await this.#setProperty(
      this.#player,
      "force-media-title",
      metadata.title ?? "",
    );
  }

  onEvent(listener: DesktopAudioEngineEventListener): () => void {
    this.#events.on("event", listener);

    return () => {
      this.#events.off("event", listener);
    };
  }

  async destroy(): Promise<void> {
    this.#destroyed = true;
    this.#unsubscribeFromPlayer?.();
    this.#unsubscribeFromPlayer = null;
    const player = this.#player;
    this.#player = null;

    if (player) {
      await player.destroy();
    }
  }

  async #ensureStarted(): Promise<MpvPlayer> {
    if (this.#destroyed) {
      throw new LibMpvAudioEngineError(
        "mpv-engine-destroyed",
        "libmpv audio engine has been destroyed.",
      );
    }

    if (this.#player) return this.#player;

    const player = this.#playerFactory();
    this.#unsubscribeFromPlayer = player.onEvent((event) =>
      this.#handleMpvEvent(event),
    );

    try {
      await player.initialize({ options: MPV_OPTIONS });

      for (const property of MPV_OBSERVED_PROPERTIES) {
        await player.observeProperty(property.name, property.format);
      }
    } catch (error) {
      this.#unsubscribeFromPlayer?.();
      this.#unsubscribeFromPlayer = null;
      await player.destroy();
      throw toLibMpvError("mpv-init-failed", error);
    }

    this.#player = player;
    return player;
  }

  #handleMpvEvent(event: MpvPlayerEvent): void {
    if (this.#destroyed) return;

    switch (event.type) {
      case "start-file":
        this.#emit({ type: "playbackStateChanged", state: "loading" });
        this.#emit({ type: "bufferingChanged", isBuffering: true });
        break;
      case "file-loaded":
        this.#hasLoadedSource = true;
        this.#emit({ type: "bufferingChanged", isBuffering: false });
        this.#emit({
          type: "playbackStateChanged",
          state: this.#isPaused ? "paused" : "playing",
        });
        this.#emitProgress();
        break;
      case "playback-restart":
        this.#emit({ type: "bufferingChanged", isBuffering: false });
        break;
      case "end-file":
        this.#handleEndFile(event);
        break;
      case "property-change":
        this.#handlePropertyChange(event);
        break;
      case "error":
        this.#emitError(event.code ?? "mpv-error", event.message);
        break;
      case "shutdown":
        this.#player = null;
        this.#hasLoadedSource = false;
        break;
    }
  }

  #handleEndFile(event: Extract<MpvPlayerEvent, { type: "end-file" }>): void {
    if (event.reason === "stop" && this.#ignoreNextStopEnd) {
      this.#ignoreNextStopEnd = false;
      return;
    }

    this.#hasLoadedSource = false;
    this.#emit({ type: "bufferingChanged", isBuffering: false });

    if (event.reason === "eof") {
      this.#emit({ type: "playbackStateChanged", state: "ended" });
      this.#emit({ type: "ended", reason: "finished" });
      return;
    }

    if (event.reason === "error") {
      this.#emitError(
        "mpv-playback-error",
        event.error ?? "mpv playback error",
      );
      return;
    }

    this.#emit({ type: "playbackStateChanged", state: "stopped" });
    this.#emit({ type: "ended", reason: "stopped" });
  }

  #handlePropertyChange(
    event: Extract<MpvPlayerEvent, { type: "property-change" }>,
  ): void {
    switch (event.name) {
      case "time-pos":
        this.#currentTime = normalizeSeconds(event.data);
        this.#emitProgress();
        break;
      case "duration": {
        const duration = normalizeSeconds(event.data);
        if (duration === this.#duration) return;

        this.#duration = duration;
        this.#emit({ type: "durationChanged", duration });
        this.#emitProgress();
        break;
      }
      case "pause":
        if (typeof event.data !== "boolean") return;

        this.#isPaused = event.data;
        if (!this.#hasLoadedSource) return;

        this.#emit({
          type: "playbackStateChanged",
          state: this.#isPaused ? "paused" : "playing",
        });
        break;
      case "paused-for-cache":
        if (typeof event.data === "boolean") {
          this.#emit({
            type: "bufferingChanged",
            isBuffering: event.data,
          });
        }
        break;
      case "cache-buffering-state":
        if (typeof event.data === "number") {
          this.#emit({
            type: "bufferingChanged",
            isBuffering: event.data > 0 && event.data < 100,
          });
        }
        break;
    }
  }

  async #command(player: MpvPlayer, args: readonly string[]): Promise<void> {
    try {
      await player.command(args);
    } catch (error) {
      throw toLibMpvError("mpv-command-failed", error);
    }
  }

  async #setProperty(
    player: MpvPlayer,
    name: string,
    value: boolean | number | string | null,
  ): Promise<void> {
    try {
      await player.setProperty(name, value);
    } catch (error) {
      throw toLibMpvError("mpv-property-failed", error);
    }
  }

  #emitProgress(): void {
    this.#emit({
      type: "progress",
      currentTime: this.#currentTime,
      duration: this.#duration,
      bufferedTime: this.#currentTime,
    });
  }

  #emitError(code: string, message: string): void {
    this.#emit({
      type: "error",
      code,
      message,
    });
  }

  #emit(event: DesktopAudioEngineEvent): void {
    this.#events.emit("event", event);
  }
}

function toLibMpvError(code: string, error: unknown): LibMpvAudioEngineError {
  if (error instanceof LibMpvAudioEngineError) return error;

  const message =
    error instanceof Error ? error.message : "libmpv audio engine failed.";

  return new LibMpvAudioEngineError(code, message);
}

function normalizeSeconds(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;

  return Math.max(0, value);
}
