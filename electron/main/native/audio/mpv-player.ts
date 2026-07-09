import type { NativeAudioMetadata } from "@aonsoku/audio-contract";

export type MpvPropertyFormat = "boolean" | "number" | "string";

export type MpvPropertyValue = boolean | number | string | null;

export type MpvPlayerEvent =
  | {
      type: "start-file";
    }
  | {
      type: "file-loaded";
    }
  | {
      type: "playback-restart";
    }
  | {
      type: "end-file";
      reason: "eof" | "stop" | "quit" | "error" | "redirect" | "unknown";
      error?: string;
    }
  | {
      type: "property-change";
      name: string;
      data: MpvPropertyValue;
    }
  | {
      type: "shutdown";
    }
  | {
      type: "error";
      code?: string;
      message: string;
    };

export type MpvPlayerEventListener = (event: MpvPlayerEvent) => void;

export interface MpvPlayerInitializeOptions {
  options: Record<string, string>;
}

export interface MpvPlayer {
  initialize(options: MpvPlayerInitializeOptions): Promise<void> | void;
  command(args: readonly string[]): Promise<void> | void;
  setProperty(name: string, value: MpvPropertyValue): Promise<void> | void;
  observeProperty(
    name: string,
    format: MpvPropertyFormat,
  ): Promise<void> | void;
  updateSystemMediaSession(
    metadata: NativeAudioMetadata,
    options: {
      state: "playing" | "paused" | "stopped";
      position: number;
      duration: number;
    },
  ): Promise<void> | void;
  clearSystemMediaSession(): Promise<void> | void;
  onEvent(listener: MpvPlayerEventListener): () => void;
  destroy(): Promise<void> | void;
}

export type MpvPlayerFactory = () => MpvPlayer;
