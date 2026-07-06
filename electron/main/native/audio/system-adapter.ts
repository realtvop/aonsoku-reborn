import { platform } from "node:process";

export interface DesktopSystemAudioAdapter {
  setVolumeHUDEnabled(enabled: boolean): Promise<void>;
  setLikeActive(active: boolean): Promise<void>;
  destroy?(): Promise<void> | void;
}

export interface DesktopSystemAudioAdapterOptions {
  platform?: NodeJS.Platform;
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
  #hudEnabled = true;
  #likeActive = false;

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
  #hudEnabled = true;
  #likeActive = false;

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
