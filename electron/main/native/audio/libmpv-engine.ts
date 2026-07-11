import { EventEmitter } from "node:events";
import type {
  NativeAudioMetadata,
  NativeAudioRemoteCommand,
} from "@aonsoku/audio-contract";
import { nativeLogger } from "../debug/native-logger";
import type {
  MpvPlayer,
  MpvPlayerEvent,
  MpvPlayerFactory,
  MpvPropertyFormat,
} from "./mpv-player";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineDiagnostics,
  DesktopAudioEngineEvent,
  DesktopAudioEngineEventListener,
  DesktopAudioEngineLoadOptions,
} from "./types";

interface ObservedMpvProperty {
  name: string;
  format: MpvPropertyFormat;
}

export interface LibMpvAudioEngineOptions {
  playerFactory: MpvPlayerFactory;
  diagnostics?: DesktopAudioEngineDiagnostics;
}

export class LibMpvAudioEngineError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "LibMpvAudioEngineError";
    this.code = code;
  }
}

export const LIBMPV_ENGINE_OPTIONS: Record<string, string> = {
  "audio-display": "no",
  "force-window": "no",
  idle: "yes",
  terminal: "no",
  vid: "no",
};

export const LIBMPV_OBSERVED_PROPERTIES: ObservedMpvProperty[] = [
  { name: "time-pos", format: "number" },
  { name: "duration", format: "number" },
  { name: "pause", format: "boolean" },
  { name: "paused-for-cache", format: "boolean" },
  { name: "cache-buffering-state", format: "number" },
];

export class LibMpvAudioEngine implements DesktopAudioEngine {
  readonly #events = new EventEmitter();
  readonly #playerFactory: MpvPlayerFactory;
  readonly #diagnostics: DesktopAudioEngineDiagnostics | undefined;
  #player: MpvPlayer | null = null;
  #unsubscribeFromPlayer: (() => void) | null = null;
  #currentTime = 0;
  #duration = 0;
  #metadata: NativeAudioMetadata = {};
  #isPaused = true;
  #hasLoadedSource = false;
  #ignoreNextStopEnd = false;
  #destroyed = false;

  constructor(options: LibMpvAudioEngineOptions) {
    this.#playerFactory = options.playerFactory;
    this.#diagnostics = options.diagnostics;
  }

  async load(options: DesktopAudioEngineLoadOptions): Promise<void> {
    nativeLogger.debug(
      `loadfile target=${options.source.target.slice(0, 80)}`,
      "libmpv-engine",
    );
    const player = await this.#ensureStarted();
    this.#ignoreNextStopEnd = this.#hasLoadedSource;
    this.#hasLoadedSource = false;
    this.#currentTime = Math.max(0, options.startTime ?? 0);
    this.#duration = normalizeSeconds(options.metadata?.duration);
    this.#metadata = options.metadata ?? {};
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
    await this.#updateSystemMediaSession("playing");
    this.#emit({ type: "playbackStateChanged", state: "playing" });
  }

  async pause(): Promise<void> {
    const player = await this.#ensureStarted();
    this.#isPaused = true;
    await this.#setProperty(player, "pause", true);
    await this.#updateSystemMediaSession("paused");
    this.#emit({ type: "playbackStateChanged", state: "paused" });
  }

  async stop(): Promise<void> {
    if (!this.#player) return;

    this.#ignoreNextStopEnd = true;
    await this.#command(this.#player, ["stop"]);
    await this.#player.clearSystemMediaSession();
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
    // Keep the system media session's elapsed playback time in sync after a
    // seek. macOS extrapolates the displayed position from the last reported
    // elapsed time + playback rate, so without this the Now Playing scrubber
    // would keep advancing from the pre-seek position until the next
    // play/pause/file-loaded update.
    this.#syncSystemMediaSession(this.#isPaused ? "paused" : "playing");
  }

  async setVolume(value: number): Promise<void> {
    const player = await this.#ensureStarted();
    await this.#setProperty(player, "volume", clampUnitVolume(value) * 100);
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
    this.#metadata = {};
    await this.#player?.clearSystemMediaSession();
    this.#emit({ type: "bufferingChanged", isBuffering: false });
    this.#emit({ type: "playbackStateChanged", state: "idle" });
  }

  async updateMetadata(metadata: NativeAudioMetadata): Promise<void> {
    if (!this.#player) return;

    this.#metadata = metadata;

    await this.#setProperty(
      this.#player,
      "force-media-title",
      metadata.title ?? "",
    );
    await this.#updateSystemMediaSession(this.#isPaused ? "paused" : "playing");
  }

  onEvent(listener: DesktopAudioEngineEventListener): () => void {
    this.#events.on("event", listener);

    return () => {
      this.#events.off("event", listener);
    };
  }

  getDiagnostics(): DesktopAudioEngineDiagnostics | undefined {
    return this.#diagnostics;
  }

  async checkAvailability(): Promise<DesktopAudioEngineDiagnostics> {
    try {
      await verifyLibMpvPlayer(this.#playerFactory);
    } catch (error) {
      nativeLogger.warn(
        `libmpv availability check failed: ${error instanceof Error ? error.message : String(error)}`,
        "libmpv-engine",
      );
      throw error;
    }
    nativeLogger.info(
      `libmpv available platformKey=${process.platform}-${process.arch}`,
      "libmpv-engine",
    );
    return (
      this.#diagnostics ?? {
        backend: "libmpv",
        status: "available",
        platformKey: `${process.platform}-${process.arch}`,
      }
    );
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

    let player: MpvPlayer;
    try {
      player = this.#playerFactory();
    } catch (error) {
      throw toLibMpvError("libmpv-unavailable", error);
    }

    this.#unsubscribeFromPlayer = player.onEvent((event) =>
      this.#handleMpvEvent(event),
    );

    try {
      await initializeLibMpvPlayer(player);
    } catch (error) {
      this.#unsubscribeFromPlayer?.();
      this.#unsubscribeFromPlayer = null;
      await destroyMpvPlayerSafely(player);
      throw error;
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
        this.#syncSystemMediaSession(this.#isPaused ? "paused" : "playing");
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
        nativeLogger.error(
          `mpv error: ${event.code ?? ""} ${event.message}`,
          "libmpv-engine",
        );
        this.#emitError(event.code ?? "mpv-error", event.message);
        break;
      case "system-media-command":
        this.#handleSystemMediaCommand(event);
        break;
      case "shutdown":
        this.#clearSystemMediaSession();
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
    this.#clearSystemMediaSession();
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
        this.#syncSystemMediaSession(this.#isPaused ? "paused" : "playing");
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

  #handleSystemMediaCommand(
    event: Extract<MpvPlayerEvent, { type: "system-media-command" }>,
  ): void {
    if (this.#destroyed) return;

    const command = event.name as NativeAudioRemoteCommand;
    if (!isSupportedSystemMediaCommand(command)) return;

    const position =
      typeof event.data === "number" && Number.isFinite(event.data)
        ? event.data
        : undefined;

    this.#emit({
      type: "systemMediaCommand",
      command,
      ...(position !== undefined ? { position } : {}),
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

  async #updateSystemMediaSession(
    state: "playing" | "paused" | "stopped",
  ): Promise<void> {
    if (!this.#player || !this.#hasLoadedSource) return;

    await this.#player.updateSystemMediaSession(this.#metadata, {
      state,
      position: this.#currentTime,
      duration: this.#duration,
    });
  }

  #syncSystemMediaSession(state: "playing" | "paused" | "stopped"): void {
    this.#updateSystemMediaSession(state).catch(() => {});
  }

  #clearSystemMediaSession(): void {
    Promise.resolve(this.#player?.clearSystemMediaSession()).catch(() => {});
  }
}

function toLibMpvError(code: string, error: unknown): LibMpvAudioEngineError {
  if (error instanceof LibMpvAudioEngineError) return error;

  const message =
    error instanceof Error ? error.message : "libmpv audio engine failed.";

  return new LibMpvAudioEngineError(code, message);
}

export interface InitializeLibMpvPlayerOptions {
  // When false, the player is initialized without claiming the system media
  // command handler. The throwaway availability-check player uses this so it
  // cannot clobber the real playback player's handler.
  registerSystemMediaSession?: boolean;
}

export async function initializeLibMpvPlayer(
  player: MpvPlayer,
  options: InitializeLibMpvPlayerOptions = {},
): Promise<void> {
  try {
    await player.initialize({
      options: LIBMPV_ENGINE_OPTIONS,
      registerSystemMediaSession: options.registerSystemMediaSession ?? true,
    });
  } catch (error) {
    throw toLibMpvError("mpv-init-failed", error);
  }

  try {
    for (const property of LIBMPV_OBSERVED_PROPERTIES) {
      await player.observeProperty(property.name, property.format);
    }
  } catch (error) {
    throw toLibMpvError("mpv-observer-failed", error);
  }
}

export async function verifyLibMpvPlayer(
  playerFactory: MpvPlayerFactory,
): Promise<void> {
  let player: MpvPlayer;

  try {
    player = playerFactory();
  } catch (error) {
    throw toLibMpvError("libmpv-unavailable", error);
  }

  try {
    // The verification player is throwaway; it must not register (and on
    // destroy clear) the global system media command handler, or it races
    // with the real playback player and leaves macOS commands undelivered.
    await initializeLibMpvPlayer(player, { registerSystemMediaSession: false });
  } finally {
    await destroyMpvPlayerSafely(player);
  }
}

async function destroyMpvPlayerSafely(player: MpvPlayer): Promise<void> {
  try {
    await player.destroy();
  } catch {
    // Preserve the original startup/load failure; destroy is best-effort here.
  }
}

function normalizeSeconds(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;

  return Math.max(0, value);
}

function clampUnitVolume(value: number): number {
  if (!Number.isFinite(value)) return 1;
  return Math.max(0, Math.min(1, value));
}

const SUPPORTED_SYSTEM_MEDIA_COMMANDS: ReadonlySet<NativeAudioRemoteCommand> =
  new Set(["play", "pause", "togglePlayPause", "next", "previous", "seek"]);

function isSupportedSystemMediaCommand(
  command: string,
): command is NativeAudioRemoteCommand {
  return SUPPORTED_SYSTEM_MEDIA_COMMANDS.has(
    command as NativeAudioRemoteCommand,
  );
}
