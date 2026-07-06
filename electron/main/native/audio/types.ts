import type {
  NativeAudioEventName,
  NativeAudioEvents,
  NativeAudioMetadata,
} from "@aonsoku/audio-contract";

export type NativeAudioServiceEvent = {
  [TEvent in NativeAudioEventName]: {
    eventName: TEvent;
    event: NativeAudioEvents[TEvent];
  };
}[NativeAudioEventName];

export type NativeAudioServiceEventListener = (
  payload: NativeAudioServiceEvent,
) => void;

export type DesktopAudioEngineEvent =
  | {
      type: "playbackStateChanged";
      state: NativeAudioEvents["playbackStateChanged"]["state"];
    }
  | {
      type: "progress";
      currentTime: number;
      duration: number;
      bufferedTime?: number;
    }
  | {
      type: "durationChanged";
      duration: number;
    }
  | {
      type: "bufferingChanged";
      isBuffering: boolean;
    }
  | {
      type: "ended";
      reason?: NativeAudioEvents["ended"]["reason"];
    }
  | {
      type: "error";
      code?: string;
      message: string;
    };

export type DesktopAudioEngineEventListener = (
  event: DesktopAudioEngineEvent,
) => void;

export interface ResolvedNativeAudioSource {
  kind: "stream" | "radio" | "native-file";
  target: string;
}

export interface DesktopAudioEngineLoadOptions {
  source: ResolvedNativeAudioSource;
  metadata?: NativeAudioMetadata;
  autoplay?: boolean;
  startTime?: number;
}

export interface DesktopAudioEngine {
  load(options: DesktopAudioEngineLoadOptions): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  stop(): Promise<void>;
  seek(position: number): Promise<void>;
  setVolume(value: number): Promise<void>;
  clear(): Promise<void>;
  updateMetadata(metadata: NativeAudioMetadata): Promise<void>;
  onEvent(listener: DesktopAudioEngineEventListener): () => void;
  destroy?(): Promise<void> | void;
}
