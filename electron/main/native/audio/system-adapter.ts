import { execFile } from "node:child_process";
import { platform } from "node:process";
import { promisify } from "node:util";
import type { NativeSystemVolumeResult } from "@aonsoku/audio-contract";

const execFileAsync = promisify(execFile);

export interface DesktopSystemAudioAdapter {
  setSystemVolume(value: number): Promise<NativeSystemVolumeResult>;
  getSystemVolume(): Promise<NativeSystemVolumeResult>;
  setVolumeHUDEnabled(enabled: boolean): Promise<void>;
  setLikeActive(active: boolean): Promise<void>;
  destroy?(): Promise<void> | void;
}

export interface DesktopSystemAudioAdapterOptions {
  platform?: NodeJS.Platform;
  runAppleScript?: (script: string) => Promise<string>;
}

export function createDesktopSystemAudioAdapter(
  options: DesktopSystemAudioAdapterOptions = {},
): DesktopSystemAudioAdapter {
  if ((options.platform ?? platform) === "darwin") {
    return new MacOsSystemAudioAdapter(options);
  }

  return new MemorySystemAudioAdapter();
}

export class MemorySystemAudioAdapter implements DesktopSystemAudioAdapter {
  #volume: number;
  #hudEnabled = true;
  #likeActive = false;

  constructor(initialVolume = 1) {
    this.#volume = clampUnitVolume(initialVolume);
  }

  setSystemVolume(value: number): Promise<NativeSystemVolumeResult> {
    this.#volume = clampUnitVolume(value);
    return Promise.resolve({ volume: this.#volume });
  }

  getSystemVolume(): Promise<NativeSystemVolumeResult> {
    return Promise.resolve({ volume: this.#volume });
  }

  setVolumeHUDEnabled(enabled: boolean): Promise<void> {
    this.#hudEnabled = enabled;
    return Promise.resolve();
  }

  setLikeActive(active: boolean): Promise<void> {
    this.#likeActive = active;
    return Promise.resolve();
  }

  get volumeHUDEnabledForTest(): boolean {
    return this.#hudEnabled;
  }

  get likeActiveForTest(): boolean {
    return this.#likeActive;
  }
}

export class MacOsSystemAudioAdapter implements DesktopSystemAudioAdapter {
  readonly #runAppleScript: (script: string) => Promise<string>;
  #fallbackVolume = 1;
  #hudEnabled = true;
  #likeActive = false;

  constructor(options: DesktopSystemAudioAdapterOptions = {}) {
    this.#runAppleScript = options.runAppleScript ?? runAppleScript;
  }

  async setSystemVolume(value: number): Promise<NativeSystemVolumeResult> {
    const clamped = clampUnitVolume(value);
    const percentage = Math.round(clamped * 100);

    await this.#runAppleScript(`set volume output volume ${percentage}`);
    this.#fallbackVolume = clamped;

    return this.getSystemVolume().catch(() => ({ volume: clamped }));
  }

  async getSystemVolume(): Promise<NativeSystemVolumeResult> {
    const output = await this.#runAppleScript(
      "output volume of (get volume settings)",
    );
    const parsed = Number.parseFloat(output.trim());

    if (!Number.isFinite(parsed)) {
      return { volume: this.#fallbackVolume };
    }

    const volume = clampUnitVolume(parsed / 100);
    this.#fallbackVolume = volume;

    return { volume };
  }

  setVolumeHUDEnabled(enabled: boolean): Promise<void> {
    this.#hudEnabled = enabled;
    return Promise.resolve();
  }

  setLikeActive(active: boolean): Promise<void> {
    this.#likeActive = active;
    return Promise.resolve();
  }

  get volumeHUDEnabledForTest(): boolean {
    return this.#hudEnabled;
  }

  get likeActiveForTest(): boolean {
    return this.#likeActive;
  }
}

export function clampUnitVolume(value: number): number {
  if (!Number.isFinite(value)) return 1;
  return Math.max(0, Math.min(1, value));
}

async function runAppleScript(script: string): Promise<string> {
  const { stdout } = await execFileAsync("osascript", ["-e", script]);
  return stdout;
}
