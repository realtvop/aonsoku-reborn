import type {
  AonsokuAudioApi,
  AonsokuAudioBridge,
  NativeAudioEventName,
  NativeAudioEvents,
} from "@aonsoku/audio-contract";
import { ipcRenderer } from "electron";

const DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL = "aonsoku-native-audio:invoke";
const DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL = "aonsoku-native-audio:event";
const DESKTOP_NATIVE_AUDIO_CAPABILITY_CHANNEL =
  "aonsoku-native-audio:capability";

export interface DesktopNativeAudioCapability {
  available: boolean;
  reason?: string;
}

export const desktopNativeAudioCapability = ipcRenderer.sendSync(
  DESKTOP_NATIVE_AUDIO_CAPABILITY_CHANNEL,
) as DesktopNativeAudioCapability;

type DesktopNativeAudioInvokePayload<
  TMethod extends keyof AonsokuAudioApi = keyof AonsokuAudioApi,
> = {
  method: TMethod;
  args: Parameters<AonsokuAudioApi[TMethod]>;
};

// All native-audio events are multiplexed over a single IPC channel. Every
// subscriber used to register its own ipcRenderer listener for that channel,
// so the listener count grew with the number of subscribers (backend + queue
// controller + remote-command observer + cache adapter + system volume ...)
// and tripped MaxListenersExceededWarning, plus every event was dispatched to
// every subscriber's wrapper. Instead, install a single dispatcher that fans
// events out to per-eventName listener sets, so the ipcRenderer listener count
// is always 1 regardless of how many subscribers exist.
type NativeAudioListenerFunc = (event: unknown) => void;
const nativeAudioListeners = new Map<
  NativeAudioEventName,
  Set<NativeAudioListenerFunc>
>();
let nativeAudioDispatcherInstalled = false;
let nativeAudioDispatcher:
  | ((
      event: unknown,
      payload: { eventName: NativeAudioEventName; event: unknown } | undefined,
    ) => void)
  | null = null;

function ensureNativeAudioDispatcher(): void {
  if (nativeAudioDispatcherInstalled) return;
  nativeAudioDispatcherInstalled = true;

  const dispatcher = (
    _event: unknown,
    payload: { eventName: NativeAudioEventName; event: unknown } | undefined,
  ) => {
    if (!payload) return;
    const listeners = nativeAudioListeners.get(payload.eventName);
    if (!listeners) return;

    for (const listener of listeners) {
      try {
        listener(payload.event);
      } catch (error) {
        // A failing listener must not break delivery to the others.
        console.error("[aonsoku-native-audio] listener threw:", error);
      }
    }
  };

  nativeAudioDispatcher = dispatcher;
  ipcRenderer.on(DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL, dispatcher);
}

/** @internal Test-only: detaches the dispatcher and clears listener sets. */
export function __resetNativeAudioDispatcherForTest(): void {
  if (nativeAudioDispatcher !== null) {
    ipcRenderer.removeListener(
      DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
      nativeAudioDispatcher,
    );
    nativeAudioDispatcher = null;
  }
  nativeAudioDispatcherInstalled = false;
  nativeAudioListeners.clear();
}

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
  clearRemotePlaybackState: () => invokeNativeAudio("clearRemotePlaybackState"),
  preload: (options) => invokeNativeAudio("preload", options),
  clear: () => invokeNativeAudio("clear"),
  storeAudioFile: (options) => invokeNativeAudio("storeAudioFile", options),
  resolveAudioFile: (options) => invokeNativeAudio("resolveAudioFile", options),
  getAudioFileSize: (options) => invokeNativeAudio("getAudioFileSize", options),
  deleteAudioFile: (options) => invokeNativeAudio("deleteAudioFile", options),
  clearAudioFiles: () => invokeNativeAudio("clearAudioFiles"),
  setContextQueue: (options) => invokeNativeAudio("setContextQueue", options),
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
    ensureNativeAudioDispatcher();

    let listeners = nativeAudioListeners.get(eventName);
    if (!listeners) {
      listeners = new Set<NativeAudioListenerFunc>();
      nativeAudioListeners.set(eventName, listeners);
    }

    const listener = listenerFunc as NativeAudioListenerFunc;
    listeners.add(listener);

    return {
      remove: () => {
        const current = nativeAudioListeners.get(eventName);
        if (!current) return;
        current.delete(listener);
        if (current.size === 0) {
          nativeAudioListeners.delete(eventName);
        }
      },
    };
  },
};
