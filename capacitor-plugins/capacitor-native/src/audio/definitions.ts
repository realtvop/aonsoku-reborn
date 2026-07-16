import type {
  AonsokuAudioApi,
  NativeAudioEventName,
  NativeAudioEvents,
} from "@aonsoku/audio-contract";
import type { Plugin, PluginListenerHandle } from "@capacitor/core";

export * from "@aonsoku/audio-contract";

export interface AonsokuNativeAudioPlugin extends Plugin, AonsokuAudioApi {
  addListener<TEvent extends NativeAudioEventName>(
    eventName: TEvent,
    listenerFunc: (event: NativeAudioEvents[TEvent]) => void,
  ): Promise<PluginListenerHandle>;
}

export type NativeAudioPlugin = AonsokuNativeAudioPlugin;
