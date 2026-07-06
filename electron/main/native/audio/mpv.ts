import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { NativeAudioMetadata } from "@aonsoku/audio-contract";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineEvent,
  DesktopAudioEngineEventListener,
  DesktopAudioEngineLoadOptions,
} from "./types";

type MpvValue = string | number | boolean | null | MpvObject | MpvValue[];

interface MpvObject {
  [key: string]: MpvValue | undefined;
}

interface MpvResponse {
  request_id?: number;
  error?: string;
  data?: MpvValue;
}

interface MpvEvent {
  event?: string;
  name?: string;
  data?: MpvValue;
  reason?: string;
  error?: string;
}

export interface MpvProcess {
  readonly stderr: NodeJS.ReadableStream | null;
  once(event: "error", listener: (error: Error) => void): this;
  once(event: "exit", listener: (code: number | null) => void): this;
  on(event: "exit", listener: (code: number | null) => void): this;
  kill(signal?: NodeJS.Signals): boolean;
}

export type MpvProcessFactory = (
  command: string,
  args: string[],
) => MpvProcess;

export interface MpvAudioEngineOptions {
  command?: string;
  connectTimeoutMs?: number;
  processFactory?: MpvProcessFactory;
}

const MPV_OBSERVED_PROPERTIES = [
  "time-pos",
  "duration",
  "pause",
  "paused-for-cache",
  "cache-buffering-state",
] as const;

export class MpvAudioEngine implements DesktopAudioEngine {
  readonly #events = new EventEmitter();
  readonly #command: string;
  readonly #connectTimeoutMs: number;
  readonly #processFactory: MpvProcessFactory;
  #process: MpvProcess | null = null;
  #socket: Socket | null = null;
  #lineBuffer = "";
  #nextRequestId = 1;
  #pendingCommands = new Map<
    number,
    {
      resolve: (response: MpvResponse) => void;
      reject: (error: Error) => void;
    }
  >();
  #currentTime = 0;
  #duration = 0;
  #isPaused = true;
  #hasLoadedSource = false;
  #ignoreNextStopEnd = false;

  constructor(options: MpvAudioEngineOptions = {}) {
    this.#command = options.command ?? "mpv";
    this.#connectTimeoutMs = options.connectTimeoutMs ?? 5000;
    this.#processFactory = options.processFactory ?? defaultMpvProcessFactory;
  }

  async load(options: DesktopAudioEngineLoadOptions): Promise<void> {
    await this.#ensureStarted();
    this.#hasLoadedSource = false;
    this.#currentTime = Math.max(0, options.startTime ?? 0);
    this.#duration = normalizeSeconds(options.metadata?.duration);
    this.#isPaused = options.autoplay !== true;
    this.#emit({ type: "playbackStateChanged", state: "loading" });
    this.#emit({ type: "bufferingChanged", isBuffering: true });

    await this.#sendCommand(["set_property", "pause", this.#isPaused]);
    await this.#sendCommand(["loadfile", options.source.target, "replace"]);

    if (this.#currentTime > 0) {
      await this.seek(this.#currentTime);
    }
  }

  async play(): Promise<void> {
    await this.#ensureStarted();
    this.#isPaused = false;
    await this.#sendCommand(["set_property", "pause", false]);
    this.#emit({ type: "playbackStateChanged", state: "playing" });
  }

  async pause(): Promise<void> {
    await this.#ensureStarted();
    this.#isPaused = true;
    await this.#sendCommand(["set_property", "pause", true]);
    this.#emit({ type: "playbackStateChanged", state: "paused" });
  }

  async stop(): Promise<void> {
    if (!this.#socket) return;

    this.#ignoreNextStopEnd = true;
    await this.#sendCommand(["stop"]);
    this.#hasLoadedSource = false;
    this.#currentTime = 0;
    this.#emit({ type: "playbackStateChanged", state: "stopped" });
    this.#emit({ type: "ended", reason: "stopped" });
  }

  async seek(position: number): Promise<void> {
    await this.#ensureStarted();
    this.#currentTime = Math.max(0, position);
    await this.#sendCommand(["seek", this.#currentTime, "absolute", "exact"]);
    this.#emitProgress();
  }

  async clear(): Promise<void> {
    if (this.#socket) {
      this.#ignoreNextStopEnd = true;
      await this.#sendCommand(["stop"]);
    }

    this.#hasLoadedSource = false;
    this.#currentTime = 0;
    this.#duration = 0;
    this.#isPaused = true;
    this.#emit({ type: "bufferingChanged", isBuffering: false });
    this.#emit({ type: "playbackStateChanged", state: "idle" });
  }

  updateMetadata(_metadata: NativeAudioMetadata): Promise<void> {
    return Promise.resolve();
  }

  onEvent(listener: DesktopAudioEngineEventListener): () => void {
    this.#events.on("event", listener);

    return () => {
      this.#events.off("event", listener);
    };
  }

  async destroy(): Promise<void> {
    for (const pending of this.#pendingCommands.values()) {
      pending.reject(new Error("mpv audio engine was destroyed"));
    }
    this.#pendingCommands.clear();

    this.#socket?.destroy();
    this.#socket = null;

    if (this.#process) {
      this.#process.kill();
      this.#process = null;
    }
  }

  async #ensureStarted(): Promise<void> {
    if (this.#socket && !this.#socket.destroyed) return;

    const ipcPath = createMpvIpcPath();
    const args = [
      "--no-terminal",
      "--idle=yes",
      "--force-window=no",
      "--audio-display=no",
      "--no-video",
      `--input-ipc-server=${ipcPath}`,
    ];

    this.#process = this.#processFactory(this.#command, args);
    this.#process.once("error", (error) => {
      this.#rejectPending(error);
      this.#emitError("mpv-spawn-failed", error.message);
    });
    this.#process.on("exit", (code) => {
      this.#socket?.destroy();
      this.#socket = null;
      this.#rejectPending(
        new Error(`mpv exited${code === null ? "" : ` with code ${code}`}`),
      );
      if (this.#hasLoadedSource) {
        this.#emitError("mpv-exited", "mpv audio process exited unexpectedly.");
      }
    });
    this.#process.stderr?.on("data", (chunk) => {
      const message = String(chunk).trim();
      if (message.length > 0) {
        this.#emitError("mpv-stderr", message);
      }
    });

    this.#socket = await connectToMpv(ipcPath, this.#connectTimeoutMs);
    this.#socket.setEncoding("utf8");
    this.#socket.on("data", (chunk) => this.#handleSocketData(String(chunk)));
    this.#socket.on("error", (error) => {
      this.#rejectPending(error);
      this.#emitError("mpv-ipc-error", error.message);
    });
    this.#socket.on("close", () => {
      this.#socket = null;
    });

    for (const property of MPV_OBSERVED_PROPERTIES) {
      await this.#sendCommand([
        "observe_property",
        this.#nextRequestId,
        property,
      ]);
    }
  }

  #handleSocketData(chunk: string): void {
    this.#lineBuffer += chunk;

    while (this.#lineBuffer.includes("\n")) {
      const [line, ...rest] = this.#lineBuffer.split("\n");
      this.#lineBuffer = rest.join("\n");
      this.#handleSocketLine(line);
    }
  }

  #handleSocketLine(line: string): void {
    if (line.trim().length === 0) return;

    const message = parseMpvMessage(line);
    if (!message) return;

    if (isMpvResponse(message)) {
      this.#handleResponse(message);
      return;
    }

    this.#handleMpvEvent(message as MpvEvent);
  }

  #handleResponse(response: MpvResponse): void {
    if (typeof response.request_id !== "number") return;

    const pending = this.#pendingCommands.get(response.request_id);
    if (!pending) return;

    this.#pendingCommands.delete(response.request_id);
    if (response.error && response.error !== "success") {
      pending.reject(new Error(response.error));
      return;
    }

    pending.resolve(response);
  }

  #handleMpvEvent(event: MpvEvent): void {
    switch (event.event) {
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
    }
  }

  #handleEndFile(event: MpvEvent): void {
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
      this.#emitError("mpv-playback-error", event.error ?? "mpv playback error");
      return;
    }

    this.#emit({ type: "playbackStateChanged", state: "stopped" });
    this.#emit({ type: "ended", reason: "stopped" });
  }

  #handlePropertyChange(event: MpvEvent): void {
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

  #sendCommand(command: MpvValue[]): Promise<MpvResponse> {
    if (!this.#socket || this.#socket.destroyed) {
      return Promise.reject(new Error("mpv IPC socket is not connected"));
    }

    const requestId = this.#nextRequestId++;
    const payload = JSON.stringify({
      command,
      request_id: requestId,
    });

    return new Promise((resolve, reject) => {
      this.#pendingCommands.set(requestId, { resolve, reject });
      this.#socket?.write(`${payload}\n`, (error) => {
        if (!error) return;

        this.#pendingCommands.delete(requestId);
        reject(error);
      });
    });
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

  #rejectPending(error: Error): void {
    for (const pending of this.#pendingCommands.values()) {
      pending.reject(error);
    }
    this.#pendingCommands.clear();
  }
}

function defaultMpvProcessFactory(
  command: string,
  args: string[],
): MpvProcess {
  return spawn(command, args, {
    stdio: ["ignore", "ignore", "pipe"],
  }) as unknown as MpvProcess;
}

function createMpvIpcPath(): string {
  const suffix = `${process.pid}-${Date.now()}-${Math.random()
    .toString(36)
    .slice(2)}`;

  if (process.platform === "win32") {
    return `\\\\.\\pipe\\aonsoku-mpv-${suffix}`;
  }

  return join(tmpdir(), `aonsoku-mpv-${suffix}.sock`);
}

function connectToMpv(path: string, timeoutMs: number): Promise<Socket> {
  const startedAt = Date.now();

  return new Promise((resolve, reject) => {
    const attempt = () => {
      const socket = createConnection(path);

      socket.once("connect", () => {
        resolve(socket);
      });
      socket.once("error", (error) => {
        socket.destroy();

        if (Date.now() - startedAt >= timeoutMs) {
          reject(error);
          return;
        }

        setTimeout(attempt, 50);
      });
    };

    attempt();
  });
}

function parseMpvMessage(line: string): MpvResponse | MpvEvent | null {
  try {
    return JSON.parse(line) as MpvResponse | MpvEvent;
  } catch {
    return null;
  }
}

function isMpvResponse(message: MpvResponse | MpvEvent): message is MpvResponse {
  return typeof (message as MpvResponse).request_id === "number";
}

function normalizeSeconds(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;

  return Math.max(0, value);
}
