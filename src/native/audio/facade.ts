import { Capacitor, registerPlugin, WebPlugin } from "@capacitor/core";
import {
  type AonsokuAudioBridge,
  type AonsokuAudioListenerHandle,
  type AonsokuNativeAudioPlugin,
  NATIVE_AUDIO_PLUGIN_NAME,
  type NativeAddToUserQueueOptions,
  type NativeAudioEventName,
  type NativeAudioEvents,
  type NativeAudioFileOptions,
  type NativeAudioLoadOptions,
  type NativeAudioMetadata,
  type NativeAudioQueueOptions,
  type NativeAudioRepeatModeOptions,
  type NativeAudioSeekOptions,
  type NativeAudioShuffleOptions,
  type NativeAudioSource,
  type NativeAudioStoreFileOptions,
  type NativeMarkAsShuffledOptions,
  type NativePlayAtIndexOptions,
  type NativeRemotePlaybackStateOptions,
  type NativeRemoveFromUserQueueOptions,
  type NativeReorderContextQueueOptions,
  type NativeSetContextQueueOptions,
  type NativeSetSleepTimerOptions,
  type NativeUpdateContextQueueOptions,
} from "./types";

export type NativeAudioUnavailableReason =
  | "unsupported-platform"
  | "missing-plugin"
  | "unhealthy-plugin";

export type NativeAudioPluginAvailability =
  | {
      available: true;
      plugin: AonsokuAudioBridge;
    }
  | {
      available: false;
      reason: NativeAudioUnavailableReason;
      message: string;
    };

export function createNativeAudioUnavailableError(method: string) {
  return new Error(
    `${NATIVE_AUDIO_PLUGIN_NAME}.${method} is only available on Electron desktop or native Capacitor platforms after the native plugin is installed.`,
  );
}

class UnavailableNativeAudioWeb
  extends WebPlugin
  implements AonsokuNativeAudioPlugin
{
  load(_options: NativeAudioLoadOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("load"));
  }

  play(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("play"));
  }

  pause(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("pause"));
  }

  stop(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("stop"));
  }

  seek(_options: NativeAudioSeekOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("seek"));
  }

  setRepeatMode(_options: NativeAudioRepeatModeOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setRepeatMode"));
  }

  setShuffle(_options: NativeAudioShuffleOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setShuffle"));
  }

  markAsShuffled(_options: NativeMarkAsShuffledOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("markAsShuffled"));
  }

  setQueue(_options: NativeAudioQueueOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setQueue"));
  }

  skipToNext(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("skipToNext"));
  }

  skipToPrevious(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("skipToPrevious"));
  }

  updateMetadata(_metadata: NativeAudioMetadata): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("updateMetadata"));
  }

  updateRemotePlaybackState(
    _options: NativeRemotePlaybackStateOptions,
  ): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("updateRemotePlaybackState"),
    );
  }

  clearRemotePlaybackState(): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("clearRemotePlaybackState"),
    );
  }

  preload(_options: { source: NativeAudioSource }): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("preload"));
  }

  clear(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("clear"));
  }

  storeAudioFile(_options: NativeAudioStoreFileOptions) {
    return Promise.reject(createNativeAudioUnavailableError("storeAudioFile"));
  }

  resolveAudioFile(_options: NativeAudioFileOptions) {
    return Promise.reject(
      createNativeAudioUnavailableError("resolveAudioFile"),
    );
  }

  getAudioFileSize(_options: NativeAudioFileOptions) {
    return Promise.reject(
      createNativeAudioUnavailableError("getAudioFileSize"),
    );
  }

  deleteAudioFile(_options: NativeAudioFileOptions) {
    return Promise.reject(createNativeAudioUnavailableError("deleteAudioFile"));
  }

  clearAudioFiles() {
    return Promise.reject(createNativeAudioUnavailableError("clearAudioFiles"));
  }

  setContextQueue(_options: NativeSetContextQueueOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setContextQueue"));
  }

  updateContextQueue(_options: NativeUpdateContextQueueOptions): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("updateContextQueue"),
    );
  }

  reorderContextQueue(
    _options: NativeReorderContextQueueOptions,
  ): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("reorderContextQueue"),
    );
  }

  addToUserQueue(_options: NativeAddToUserQueueOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("addToUserQueue"));
  }

  removeFromUserQueue(
    _options: NativeRemoveFromUserQueueOptions,
  ): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("removeFromUserQueue"),
    );
  }

  clearUserQueue(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("clearUserQueue"));
  }

  playAtIndex(_options: NativePlayAtIndexOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("playAtIndex"));
  }

  resolveSongs() {
    return Promise.reject(createNativeAudioUnavailableError("resolveSongs"));
  }

  getFullState() {
    return Promise.reject(createNativeAudioUnavailableError("getFullState"));
  }

  getScrobbleBuffer() {
    return Promise.reject(
      createNativeAudioUnavailableError("getScrobbleBuffer"),
    );
  }

  clearScrobbleBuffer(): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("clearScrobbleBuffer"),
    );
  }

  downloadAudioFile(): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("downloadAudioFile"),
    );
  }

  cancelDownload(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("cancelDownload"));
  }

  setSystemVolume(): Promise<never> {
    return Promise.reject(createNativeAudioUnavailableError("setSystemVolume"));
  }

  getSystemVolume(): Promise<never> {
    return Promise.reject(createNativeAudioUnavailableError("getSystemVolume"));
  }

  setVolumeHUDEnabled(): Promise<void> {
    return Promise.resolve();
  }

  setLikeActive(): Promise<void> {
    return Promise.resolve();
  }

  setSleepTimer(_options: NativeSetSleepTimerOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setSleepTimer"));
  }

  cancelSleepTimer(): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("cancelSleepTimer"),
    );
  }

  getSleepTimerRemaining() {
    return Promise.reject(
      createNativeAudioUnavailableError("getSleepTimerRemaining"),
    );
  }
}

export const AonsokuNativeAudio = registerPlugin<AonsokuNativeAudioPlugin>(
  NATIVE_AUDIO_PLUGIN_NAME,
  {
    web: () => new UnavailableNativeAudioWeb(),
  },
);

function getDesktopNativeAudioBridge(): AonsokuAudioBridge | null {
  if (typeof window === "undefined") return null;

  return window.aonsokuNativeAudio ?? null;
}

export function getNativeAudioPluginAvailability(): NativeAudioPluginAvailability {
  const desktopBridge = getDesktopNativeAudioBridge();
  if (desktopBridge) {
    const capability = window.aonsokuNativeAudioCapability;
    if (!capability?.available) {
      return {
        available: false,
        reason: "unhealthy-plugin",
        message:
          capability?.reason ??
          "Electron desktop native audio did not complete its capability handshake.",
      };
    }
    return {
      available: true,
      plugin: desktopBridge,
    };
  }

  if (!Capacitor.isNativePlatform()) {
    return {
      available: false,
      reason: "unsupported-platform",
      message: `${NATIVE_AUDIO_PLUGIN_NAME} requires Electron desktop or a native Capacitor platform.`,
    };
  }

  if (!Capacitor.isPluginAvailable(NATIVE_AUDIO_PLUGIN_NAME)) {
    return {
      available: false,
      reason: "missing-plugin",
      message: `${NATIVE_AUDIO_PLUGIN_NAME} native plugin is not available on ${Capacitor.getPlatform()}.`,
    };
  }

  const platform = Capacitor.getPlatform();
  if (platform === "android") {
    return {
      available: true,
      plugin: AonsokuNativeAudio,
    };
  }

  return {
    available: true,
    plugin: AonsokuNativeAudio,
  };
}

export function isNativeAudioPluginAvailable() {
  return getNativeAudioPluginAvailability().available;
}

export async function addNativeAudioListener<
  TEvent extends NativeAudioEventName,
>(
  eventName: TEvent,
  listener: (event: NativeAudioEvents[TEvent]) => void,
): Promise<AonsokuAudioListenerHandle> {
  const availability = getNativeAudioPluginAvailability();
  if (!availability.available) {
    throw new Error(availability.message);
  }

  return availability.plugin.addListener(eventName, listener);
}

export async function tryAddNativeAudioListener<
  TEvent extends NativeAudioEventName,
>(
  eventName: TEvent,
  listener: (event: NativeAudioEvents[TEvent]) => void,
): Promise<AonsokuAudioListenerHandle | null> {
  const availability = getNativeAudioPluginAvailability();
  if (!availability.available) return null;

  return availability.plugin.addListener(eventName, listener);
}
