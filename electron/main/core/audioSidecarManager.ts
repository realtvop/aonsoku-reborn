import { spawn as spawnChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import {
  createInterface,
  type Interface as ReadlineInterface,
} from "node:readline";
import type { Readable, Writable } from "node:stream";
import type {
  NativeAudioEvents,
  NativeAudioLoadOptions,
  NativeAudioSeekOptions,
} from "@aonsoku/audio-contract";

type RequestId = string | number;
type JsonObject = Record<string, unknown>;

type MvpAudioEventName =
  | "playbackStateChanged"
  | "progress"
  | "durationChanged"
  | "bufferingChanged"
  | "ended"
  | "error";

type MvpAudioEvents = Pick<NativeAudioEvents, MvpAudioEventName>;

export type AudioSidecarEventEnvelope<
  TEvent extends MvpAudioEventName = MvpAudioEventName,
> = {
  event: TEvent;
  payload: MvpAudioEvents[TEvent];
};

export type AudioSidecarRequestMethod =
  | "load"
  | "play"
  | "pause"
  | "stop"
  | "seek";

export type AudioSidecarRequestParams = {
  load: NativeAudioLoadOptions;
  play: undefined;
  pause: undefined;
  stop: undefined;
  seek: NativeAudioSeekOptions;
};

type JsonRpcSuccess = {
  jsonrpc: "2.0";
  id: RequestId;
  result: JsonObject;
};

type JsonRpcFailure = {
  jsonrpc: "2.0";
  id?: RequestId;
  error: {
    code: string;
    message: string;
  };
};

type PendingRequest = {
  resolve: () => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

export type AudioSidecarSpawnCommand = {
  command: string;
  args: string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
};

export type AudioSidecarProcess = {
  stdin: Writable | null;
  stdout: Readable | null;
  stderr: Readable | null;
  kill: () => boolean;
  on: (
    event: "error" | "exit",
    listener: (
      errorOrCode: Error | number | null,
      signal?: string | null,
    ) => void,
  ) => AudioSidecarProcess;
};

export type SpawnAudioSidecar = (
  command: AudioSidecarSpawnCommand,
) => AudioSidecarProcess;

export type AudioSidecarManagerOptions = {
  spawnCommand?: AudioSidecarSpawnCommand;
  spawn?: SpawnAudioSidecar;
  requestIdPrefix?: string;
  requestTimeoutMs?: number;
  audioEventSink?: (envelope: AudioSidecarEventEnvelope) => void;
};

export type ResolveAudioSidecarSpawnOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  platform?: NodeJS.Platform;
  resourcesPath?: string;
};

export const DEFAULT_AUDIO_SIDECAR_REQUEST_TIMEOUT_MS = 10_000;

export class AudioSidecarError extends Error {
  constructor(
    message: string,
    public readonly code?: string,
  ) {
    super(message);
    this.name = "AudioSidecarError";
  }
}

export class AudioSidecarManager {
  private readonly emitter = new EventEmitter();
  private readonly pending = new Map<string, PendingRequest>();
  private readonly spawnCommand: AudioSidecarSpawnCommand;
  private readonly spawn: SpawnAudioSidecar;
  private readonly requestIdPrefix: string;
  private readonly requestTimeoutMs: number;
  private readonly audioEventSink?: (
    envelope: AudioSidecarEventEnvelope,
  ) => void;
  private child: AudioSidecarProcess | null = null;
  private lineReader: ReadlineInterface | null = null;
  private requestSequence = 0;
  private isStopping = false;

  constructor(options: AudioSidecarManagerOptions = {}) {
    this.spawnCommand =
      options.spawnCommand ?? resolveAudioSidecarSpawnCommand();
    this.spawn = options.spawn ?? spawnAudioSidecarProcess;
    this.requestIdPrefix = options.requestIdPrefix ?? "playerd";
    this.requestTimeoutMs =
      options.requestTimeoutMs ?? DEFAULT_AUDIO_SIDECAR_REQUEST_TIMEOUT_MS;
    this.audioEventSink = options.audioEventSink;
  }

  get running(): boolean {
    return this.child !== null;
  }

  start(): void {
    if (this.child) return;

    this.isStopping = false;

    const child = this.spawn(this.spawnCommand);

    if (!child.stdin || !child.stdout || !child.stderr) {
      throw new AudioSidecarError(
        "aonsoku-playerd must be spawned with stdin/stdout/stderr pipes",
      );
    }

    this.child = child;
    this.lineReader = createInterface({
      input: child.stdout,
      crlfDelay: Number.POSITIVE_INFINITY,
    });

    this.lineReader.on("line", (line) => {
      this.handleLine(line);
    });

    child.stderr.on("data", (chunk) => {
      this.emitter.emit("stderr", chunk.toString());
    });

    child.on("error", (errorOrCode) => {
      const error =
        errorOrCode instanceof Error
          ? errorOrCode
          : new AudioSidecarError("aonsoku-playerd process error");
      this.handleProcessFailure(error);
    });

    child.on("exit", (errorOrCode, signal) => {
      const code = typeof errorOrCode === "number" ? errorOrCode : null;
      this.handleExit(code, signal ?? null);
    });
  }

  stop(): void {
    if (!this.child) return;

    this.isStopping = true;
    this.lineReader?.close();
    this.lineReader = null;
    this.child.kill();
    this.child = null;
    this.rejectPending(
      new AudioSidecarError("aonsoku-playerd stopped before replying"),
    );
  }

  load(options: NativeAudioLoadOptions): Promise<void> {
    return this.sendRequest("load", options);
  }

  play(): Promise<void> {
    return this.sendRequest("play");
  }

  pause(): Promise<void> {
    return this.sendRequest("pause");
  }

  stopPlayback(): Promise<void> {
    return this.sendRequest("stop");
  }

  seek(options: NativeAudioSeekOptions): Promise<void> {
    return this.sendRequest("seek", options);
  }

  onAudioEvent(
    listener: (envelope: AudioSidecarEventEnvelope) => void,
  ): () => void {
    this.emitter.on("audio-event", listener);

    return () => {
      this.emitter.off("audio-event", listener);
    };
  }

  onSidecarError(listener: (error: Error) => void): () => void {
    this.emitter.on("sidecar-error", listener);

    return () => {
      this.emitter.off("sidecar-error", listener);
    };
  }

  onStderr(listener: (line: string) => void): () => void {
    this.emitter.on("stderr", listener);

    return () => {
      this.emitter.off("stderr", listener);
    };
  }

  private sendRequest<TMethod extends AudioSidecarRequestMethod>(
    method: TMethod,
    params?: AudioSidecarRequestParams[TMethod],
  ): Promise<void> {
    if (!this.child?.stdin) {
      return Promise.reject(
        new AudioSidecarError("aonsoku-playerd is not running"),
      );
    }

    const id = this.nextRequestId(method);
    const request = buildJsonRpcRequest(id, method, params);
    const line = `${JSON.stringify(request)}\n`;

    return new Promise((resolveRequest, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new AudioSidecarError(
            `aonsoku-playerd request timed out: ${method}`,
            "REQUEST_TIMEOUT",
          ),
        );
      }, this.requestTimeoutMs);

      this.pending.set(id, {
        resolve: resolveRequest,
        reject,
        timeout,
      });

      this.child?.stdin?.write(line, (error) => {
        if (!error) return;

        this.removePending(id);
        reject(error);
      });
    });
  }

  private nextRequestId(method: AudioSidecarRequestMethod): string {
    this.requestSequence += 1;

    return `${this.requestIdPrefix}:${method}:${this.requestSequence}`;
  }

  private handleLine(line: string): void {
    if (!line.trim()) return;

    let message: unknown;

    try {
      message = JSON.parse(line);
    } catch (error) {
      this.emitError(
        new AudioSidecarError(
          `invalid aonsoku-playerd JSON line: ${String(error)}`,
        ),
      );
      return;
    }

    if (isAudioEventEnvelope(message)) {
      this.emitAudioEvent(message);
      return;
    }

    if (isJsonObject(message) && typeof message.event === "string") {
      this.emitError(
        new AudioSidecarError(
          `invalid aonsoku-playerd event payload: ${message.event}`,
        ),
      );
      return;
    }

    if (isJsonRpcFailure(message)) {
      this.rejectResponse(message);
      return;
    }

    if (isJsonRpcSuccess(message)) {
      this.resolveResponse(message);
      return;
    }

    this.emitError(
      new AudioSidecarError("unrecognized aonsoku-playerd message"),
    );
  }

  private emitAudioEvent(envelope: AudioSidecarEventEnvelope): void {
    this.audioEventSink?.(envelope);
    this.emitter.emit("audio-event", envelope);
    this.emitter.emit(envelope.event, envelope.payload);
  }

  private resolveResponse(response: JsonRpcSuccess): void {
    const pending = this.pending.get(String(response.id));
    if (!pending) return;

    this.removePending(String(response.id));
    pending.resolve();
  }

  private rejectResponse(response: JsonRpcFailure): void {
    if (response.id === undefined) {
      this.emitError(
        new AudioSidecarError(response.error.message, response.error.code),
      );
      return;
    }

    const pending = this.pending.get(String(response.id));
    if (!pending) return;

    this.removePending(String(response.id));
    pending.reject(
      new AudioSidecarError(response.error.message, response.error.code),
    );
  }

  private handleProcessFailure(error: Error): void {
    this.child = null;
    this.lineReader?.close();
    this.lineReader = null;
    this.rejectPending(error);
    this.emitError(error);
  }

  private handleExit(code: number | null, signal: string | null): void {
    this.child = null;
    this.lineReader?.close();
    this.lineReader = null;

    if (this.isStopping) {
      this.isStopping = false;
      return;
    }

    const detail =
      signal === null ? `exit code ${String(code)}` : `signal ${signal}`;
    const error = new AudioSidecarError(
      `aonsoku-playerd exited with ${detail}`,
    );

    this.rejectPending(error);
    this.emitError(error);
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }

    this.pending.clear();
  }

  private removePending(id: string): void {
    const pending = this.pending.get(id);
    if (!pending) return;

    clearTimeout(pending.timeout);
    this.pending.delete(id);
  }

  private emitError(error: Error): void {
    this.emitter.emit("sidecar-error", error);
  }
}

export function resolveAudioSidecarSpawnCommand(
  options: ResolveAudioSidecarSpawnOptions = {},
): AudioSidecarSpawnCommand {
  const env = options.env ?? process.env;
  const platform = options.platform ?? process.platform;
  const cwd = options.cwd ?? process.cwd();
  const executableName =
    platform === "win32" ? "aonsoku-playerd.exe" : "aonsoku-playerd";

  if (env.AONSOKU_PLAYERD_PATH) {
    return {
      command: env.AONSOKU_PLAYERD_PATH,
      args: [],
      cwd: dirname(env.AONSOKU_PLAYERD_PATH),
      env,
    };
  }

  if (options.resourcesPath) {
    const packagedBinary = join(options.resourcesPath, "bin", executableName);

    if (existsSync(packagedBinary)) {
      return {
        command: packagedBinary,
        args: [],
        cwd: dirname(packagedBinary),
        env,
      };
    }
  }

  const crateDir = resolve(cwd, "desktop/aonsoku-playerd");
  const debugBinary = join(crateDir, "target", "debug", executableName);

  if (existsSync(debugBinary)) {
    return {
      command: debugBinary,
      args: [],
      cwd: crateDir,
      env,
    };
  }

  return {
    command: "cargo",
    args: ["run", "--quiet", "--manifest-path", join(crateDir, "Cargo.toml")],
    cwd: crateDir,
    env,
  };
}

export function resolveAudioSidecarRequestTimeoutMs(
  env: NodeJS.ProcessEnv = process.env,
): number {
  const raw = env.AONSOKU_PLAYERD_REQUEST_TIMEOUT_MS;
  if (!raw) return DEFAULT_AUDIO_SIDECAR_REQUEST_TIMEOUT_MS;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return DEFAULT_AUDIO_SIDECAR_REQUEST_TIMEOUT_MS;
  }

  return parsed;
}

function spawnAudioSidecarProcess(
  command: AudioSidecarSpawnCommand,
): AudioSidecarProcess {
  return spawnChildProcess(command.command, command.args, {
    cwd: command.cwd,
    env: command.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function buildJsonRpcRequest<TMethod extends AudioSidecarRequestMethod>(
  id: string,
  method: TMethod,
  params?: AudioSidecarRequestParams[TMethod],
): JsonObject {
  const request: JsonObject = {
    jsonrpc: "2.0",
    id,
    method,
  };

  if (params !== undefined) {
    request.params = params;
  }

  return request;
}

function isAudioEventEnvelope(
  message: unknown,
): message is AudioSidecarEventEnvelope {
  if (!isJsonObject(message)) return false;
  if (typeof message.event !== "string") return false;

  if (!isMvpAudioEventName(message.event)) return false;

  return isValidMvpAudioEventPayload(message.event, message.payload);
}

function isJsonRpcSuccess(message: unknown): message is JsonRpcSuccess {
  if (!isJsonObject(message)) return false;

  return (
    message.jsonrpc === "2.0" &&
    isRequestId(message.id) &&
    isJsonObject(message.result)
  );
}

function isJsonRpcFailure(message: unknown): message is JsonRpcFailure {
  if (!isJsonObject(message)) return false;
  if (message.jsonrpc !== "2.0") return false;
  if (message.id !== undefined && !isRequestId(message.id)) return false;
  if (!isJsonObject(message.error)) return false;

  return (
    typeof message.error.code === "string" &&
    typeof message.error.message === "string"
  );
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRequestId(value: unknown): value is RequestId {
  return typeof value === "string" || typeof value === "number";
}

function isMvpAudioEventName(value: string): value is MvpAudioEventName {
  return (
    value === "playbackStateChanged" ||
    value === "progress" ||
    value === "durationChanged" ||
    value === "bufferingChanged" ||
    value === "ended" ||
    value === "error"
  );
}

function isValidMvpAudioEventPayload(
  eventName: MvpAudioEventName,
  payload: unknown,
): payload is MvpAudioEvents[MvpAudioEventName] {
  if (!isJsonObject(payload)) return false;
  if (
    payload.requestId !== undefined &&
    typeof payload.requestId !== "string"
  ) {
    return false;
  }

  switch (eventName) {
    case "playbackStateChanged":
      return isPlaybackState(payload.state);
    case "progress":
      return (
        isNumber(payload.currentTime) &&
        isNumber(payload.duration) &&
        (payload.bufferedTime === undefined || isNumber(payload.bufferedTime))
      );
    case "durationChanged":
      return isNumber(payload.duration);
    case "bufferingChanged":
      return typeof payload.isBuffering === "boolean";
    case "ended":
      return (
        payload.reason === undefined ||
        payload.reason === "finished" ||
        payload.reason === "stopped"
      );
    case "error":
      return (
        typeof payload.message === "string" &&
        (payload.code === undefined || typeof payload.code === "string")
      );
  }
}

function isPlaybackState(value: unknown): boolean {
  return (
    value === "idle" ||
    value === "loading" ||
    value === "playing" ||
    value === "paused" ||
    value === "stopped" ||
    value === "ended" ||
    value === "failed"
  );
}

function isNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}
