import type {
  AonsokuAudioApi,
  NativeAudioEventName,
  NativeAudioEvents,
} from "@aonsoku/audio-contract";
import { BrowserWindow, ipcMain } from "electron";
import {
  type DesktopAudioDownloadUrlResolver,
  NativeAudioService,
} from "./service";

export const DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL =
  "aonsoku-native-audio:invoke";

export const DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL = "aonsoku-native-audio:event";

export type DesktopNativeAudioInvokePayload<
  TMethod extends keyof AonsokuAudioApi = keyof AonsokuAudioApi,
> = {
  method: TMethod;
  args: Parameters<AonsokuAudioApi[TMethod]>;
};

export type DesktopNativeAudioEventPayload<
  TEvent extends NativeAudioEventName = NativeAudioEventName,
> = {
  eventName: TEvent;
  event: NativeAudioEvents[TEvent];
};

let streamUrlResolver = (url: string): string => url;
let downloadUrlResolver: DesktopAudioDownloadUrlResolver = () => null;
let artworkUrlResolver = (artworkUrl: string | undefined): string | undefined =>
  artworkUrl;

export const desktopNativeAudioService = new NativeAudioService({
  streamUrlResolver: (url) => streamUrlResolver(url),
  downloadUrlResolver: (options) => downloadUrlResolver(options),
  artworkUrlResolver: (artworkUrl) => artworkUrlResolver(artworkUrl),
});
let unsubscribeFromNativeAudioEvents: (() => void) | null = null;

type DesktopNativeAudioServiceMethod = (
  ...args: Parameters<AonsokuAudioApi[keyof AonsokuAudioApi]>
) => ReturnType<AonsokuAudioApi[keyof AonsokuAudioApi]>;

export function setupDesktopNativeAudioIpc(
  window?: BrowserWindow | null,
  networking?: {
    streamUrlResolver: (url: string) => string;
    downloadUrlResolver: DesktopAudioDownloadUrlResolver;
    artworkUrlResolver?: (artworkUrl: string | undefined) => string | undefined;
  },
): void {
  if (networking) {
    streamUrlResolver = networking.streamUrlResolver;
    downloadUrlResolver = networking.downloadUrlResolver;
    if (networking.artworkUrlResolver) {
      artworkUrlResolver = networking.artworkUrlResolver;
    }
  }
  ipcMain.removeHandler(DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL);
  unsubscribeFromNativeAudioEvents?.();
  unsubscribeFromNativeAudioEvents = desktopNativeAudioService.onEvent(
    ({ eventName, event }) => {
      const windows =
        window && !window.isDestroyed()
          ? [window]
          : BrowserWindow.getAllWindows();

      for (const target of windows) {
        sendDesktopNativeAudioEvent(target, eventName, event);
      }
    },
  );
  ipcMain.handle(
    DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
    async (_, payload: DesktopNativeAudioInvokePayload) => {
      const method = desktopNativeAudioService[payload.method];
      if (typeof method !== "function") {
        throw new Error(
          `Unknown desktop native audio method ${payload.method}`,
        );
      }

      return (method as DesktopNativeAudioServiceMethod).apply(
        desktopNativeAudioService,
        payload.args,
      );
    },
  );
}

export function destroyDesktopNativeAudioService(): Promise<void> | void {
  ipcMain.removeHandler(DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL);
  unsubscribeFromNativeAudioEvents?.();
  unsubscribeFromNativeAudioEvents = null;

  return desktopNativeAudioService.destroy();
}

export function sendDesktopNativeAudioEvent<
  TEvent extends NativeAudioEventName,
>(
  window: BrowserWindow,
  eventName: TEvent,
  event: NativeAudioEvents[TEvent],
): void {
  if (window.isDestroyed()) return;

  window.webContents.send(DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL, {
    eventName,
    event,
  } satisfies DesktopNativeAudioEventPayload<TEvent>);
}
