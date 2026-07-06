import { EventEmitter } from "node:events";
import type { NativeAudioMetadata } from "@aonsoku/audio-contract";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineEvent,
  DesktopAudioEngineEventListener,
  DesktopAudioEngineLoadOptions,
} from "./types";

export class DesktopNativeAudioUnavailableError extends Error {
  readonly code = "libmpv-unavailable";

  constructor(reason: string) {
    super(`Desktop native audio is unavailable: ${reason}`);
    this.name = "DesktopNativeAudioUnavailableError";
  }
}

export class UnavailableDesktopAudioEngine implements DesktopAudioEngine {
  readonly #events = new EventEmitter();
  readonly #reason: string;

  constructor(reason: string) {
    this.#reason = reason;
  }

  load(_options: DesktopAudioEngineLoadOptions): Promise<void> {
    return this.#reject();
  }

  play(): Promise<void> {
    return this.#reject();
  }

  pause(): Promise<void> {
    return this.#reject();
  }

  stop(): Promise<void> {
    return this.#reject();
  }

  seek(_position: number): Promise<void> {
    return this.#reject();
  }

  setVolume(_value: number): Promise<void> {
    return this.#reject();
  }

  clear(): Promise<void> {
    return Promise.resolve();
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

  #reject(): Promise<never> {
    const error = new DesktopNativeAudioUnavailableError(this.#reason);
    this.#emit({
      type: "error",
      code: error.code,
      message: error.message,
    });

    return Promise.reject(error);
  }

  #emit(event: DesktopAudioEngineEvent): void {
    this.#events.emit("event", event);
  }
}
