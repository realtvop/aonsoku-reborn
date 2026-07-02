import type {
  NativeAudioLoadOptions,
  NativeAudioSeekOptions,
} from "@aonsoku/audio-contract";
import {
  type AudioSidecarEventEnvelope,
  AudioSidecarManager,
} from "./audioSidecarManager";

export type AudioSidecarBridgeErrorPayload = {
  message: string;
  code?: string;
};

export type AudioSidecarBridgeManager = Pick<
  AudioSidecarManager,
  | "running"
  | "start"
  | "stop"
  | "load"
  | "play"
  | "pause"
  | "stopPlayback"
  | "seek"
  | "onAudioEvent"
  | "onSidecarError"
>;

export type AudioSidecarBridgeWindow = {
  isDestroyed(): boolean;
  webContents: {
    send(channel: string, payload: unknown): void;
  };
};

export type AudioSidecarBridgeOptions = {
  enabled: boolean;
  getWindow: () => AudioSidecarBridgeWindow | null;
  managerFactory?: () => AudioSidecarBridgeManager;
  eventChannel: string;
  errorChannel: string;
};

export class AudioSidecarBridgeDisabledError extends Error {
  constructor() {
    super("aonsoku-playerd bridge is disabled");
    this.name = "AudioSidecarBridgeDisabledError";
  }
}

export class AudioSidecarBridge {
  private readonly enabled: boolean;
  private readonly getWindow: () => AudioSidecarBridgeWindow | null;
  private readonly managerFactory: () => AudioSidecarBridgeManager;
  private readonly eventChannel: string;
  private readonly errorChannel: string;
  private manager: AudioSidecarBridgeManager | null = null;
  private cleanupListeners: Array<() => void> = [];

  constructor(options: AudioSidecarBridgeOptions) {
    this.enabled = options.enabled;
    this.getWindow = options.getWindow;
    this.managerFactory =
      options.managerFactory ?? (() => new AudioSidecarManager());
    this.eventChannel = options.eventChannel;
    this.errorChannel = options.errorChannel;
  }

  isAvailable(): boolean {
    return this.enabled;
  }

  start(): void {
    this.ensureStarted();
  }

  stop(): void {
    this.manager?.stop();
  }

  async load(options: NativeAudioLoadOptions): Promise<void> {
    await this.ensureStarted().load(options);
  }

  async play(): Promise<void> {
    await this.ensureStarted().play();
  }

  async pause(): Promise<void> {
    await this.ensureStarted().pause();
  }

  async stopPlayback(): Promise<void> {
    await this.ensureStarted().stopPlayback();
  }

  async seek(options: NativeAudioSeekOptions): Promise<void> {
    await this.ensureStarted().seek(options);
  }

  dispose(): void {
    for (const cleanup of this.cleanupListeners) {
      cleanup();
    }

    this.cleanupListeners = [];
    this.manager?.stop();
    this.manager = null;
  }

  private ensureStarted(): AudioSidecarBridgeManager {
    this.ensureEnabled();

    const manager = this.getManager();
    if (!manager.running) {
      manager.start();
    }

    return manager;
  }

  private getManager(): AudioSidecarBridgeManager {
    if (this.manager) return this.manager;

    const manager = this.managerFactory();
    this.cleanupListeners = [
      manager.onAudioEvent((event) => {
        this.send(this.eventChannel, event);
      }),
      manager.onSidecarError((error) => {
        this.send(this.errorChannel, serializeError(error));
      }),
    ];
    this.manager = manager;

    return manager;
  }

  private ensureEnabled(): void {
    if (this.enabled) return;

    throw new AudioSidecarBridgeDisabledError();
  }

  private send(channel: string, payload: unknown): void {
    const window = this.getWindow();
    if (!window || window.isDestroyed()) return;

    window.webContents.send(channel, payload);
  }
}

export function isAudioSidecarBridgeEnabled(
  env: NodeJS.ProcessEnv,
  isDev: boolean,
): boolean {
  return isDev && env.AONSOKU_PLAYERD_BRIDGE === "1";
}

function serializeError(error: Error): AudioSidecarBridgeErrorPayload {
  const code = (error as { code?: unknown }).code;

  return {
    message: error.message,
    ...(typeof code === "string" ? { code } : {}),
  };
}

export type { AudioSidecarEventEnvelope };
