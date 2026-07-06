import type {
  AonsokuAudioApi,
  AonsokuAudioBridge,
  NativeAudioEventName,
  NativeAudioEvents,
} from "@aonsoku/audio-contract";
import { ipcRenderer } from "electron";
import {
  DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
  DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
  type DesktopNativeAudioEventPayload,
  type DesktopNativeAudioInvokePayload,
} from "../main/native/audio/ipc";

function invokeNativeAudio<TMethod extends keyof AonsokuAudioApi>(
  method: TMethod,
  ...args: Parameters<AonsokuAudioApi[TMethod]>
): ReturnType<AonsokuAudioApi[TMethod]> {
  return ipcRenderer.invoke(DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL, {
    method,
    args,
  } satisfies DesktopNativeAudioInvokePayload<TMethod>) as ReturnType<
    AonsokuAudioApi[TMethod]
  >;
}

export const aonsokuNativeAudioBridge: AonsokuAudioBridge = {
  load: (options) => invokeNativeAudio("load", options),
  play: () => invokeNativeAudio("play"),
  pause: () => invokeNativeAudio("pause"),
  stop: () => invokeNativeAudio("stop"),
  seek: (options) => invokeNativeAudio("seek", options),
  setRepeatMode: (options) => invokeNativeAudio("setRepeatMode", options),
  setShuffle: (options) => invokeNativeAudio("setShuffle", options),
  markAsShuffled: (options) => invokeNativeAudio("markAsShuffled", options),
  setQueue: (options) => invokeNativeAudio("setQueue", options),
  skipToNext: () => invokeNativeAudio("skipToNext"),
  skipToPrevious: () => invokeNativeAudio("skipToPrevious"),
  updateMetadata: (metadata) => invokeNativeAudio("updateMetadata", metadata),
  updateRemotePlaybackState: (options) =>
    invokeNativeAudio("updateRemotePlaybackState", options),
  clearRemotePlaybackState: () =>
    invokeNativeAudio("clearRemotePlaybackState"),
  preload: (options) => invokeNativeAudio("preload", options),
  clear: () => invokeNativeAudio("clear"),
  storeAudioFile: (options) => invokeNativeAudio("storeAudioFile", options),
  resolveAudioFile: (options) => invokeNativeAudio("resolveAudioFile", options),
  getAudioFileSize: (options) =>
    invokeNativeAudio("getAudioFileSize", options),
  deleteAudioFile: (options) => invokeNativeAudio("deleteAudioFile", options),
  clearAudioFiles: () => invokeNativeAudio("clearAudioFiles"),
  setContextQueue: (options) =>
    invokeNativeAudio("setContextQueue", options),
  updateContextQueue: (options) =>
    invokeNativeAudio("updateContextQueue", options),
  reorderContextQueue: (options) =>
    invokeNativeAudio("reorderContextQueue", options),
  addToUserQueue: (options) => invokeNativeAudio("addToUserQueue", options),
  removeFromUserQueue: (options) =>
    invokeNativeAudio("removeFromUserQueue", options),
  clearUserQueue: () => invokeNativeAudio("clearUserQueue"),
  playAtIndex: (options) => invokeNativeAudio("playAtIndex", options),
  getFullState: () => invokeNativeAudio("getFullState"),
  resolveSongs: (options) => invokeNativeAudio("resolveSongs", options),
  getScrobbleBuffer: () => invokeNativeAudio("getScrobbleBuffer"),
  clearScrobbleBuffer: () => invokeNativeAudio("clearScrobbleBuffer"),
  downloadAudioFile: (options) =>
    invokeNativeAudio("downloadAudioFile", options),
  cancelDownload: (options) => invokeNativeAudio("cancelDownload", options),
  setSystemVolume: (options) => invokeNativeAudio("setSystemVolume", options),
  getSystemVolume: () => invokeNativeAudio("getSystemVolume"),
  setVolumeHUDEnabled: (options) =>
    invokeNativeAudio("setVolumeHUDEnabled", options),
  setLikeActive: (options) => invokeNativeAudio("setLikeActive", options),
  setSleepTimer: (options) => invokeNativeAudio("setSleepTimer", options),
  cancelSleepTimer: () => invokeNativeAudio("cancelSleepTimer"),
  getSleepTimerRemaining: () => invokeNativeAudio("getSleepTimerRemaining"),
  addListener: async <TEvent extends NativeAudioEventName>(
    eventName: TEvent,
    listenerFunc: (event: NativeAudioEvents[TEvent]) => void,
  ) => {
    const wrappedListener = (
      _event: Electron.IpcRendererEvent,
      payload: DesktopNativeAudioEventPayload<TEvent>,
    ) => {
      if (payload.eventName !== eventName) return;

      listenerFunc(payload.event);
    };

    ipcRenderer.on(DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL, wrappedListener);

    return {
      remove: () => {
        ipcRenderer.removeListener(
          DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
          wrappedListener,
        );
      },
    };
  },
};
