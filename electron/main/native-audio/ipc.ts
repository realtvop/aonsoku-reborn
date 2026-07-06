import type {
  AonsokuAudioApi,
  NativeAudioEventName,
  NativeAudioEvents,
} from "@aonsoku/audio-contract";
import { BrowserWindow, ipcMain } from "electron";
import { DesktopNativeAudioService } from "./service";

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

const desktopNativeAudioService = new DesktopNativeAudioService();

type DesktopNativeAudioServiceMethod = (
  ...args: Parameters<AonsokuAudioApi[keyof AonsokuAudioApi]>
) => ReturnType<AonsokuAudioApi[keyof AonsokuAudioApi]>;

export function setupDesktopNativeAudioIpc(): void {
  ipcMain.removeHandler(DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL);
  ipcMain.handle(
    DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
    async (_, payload: DesktopNativeAudioInvokePayload) => {
      const method = desktopNativeAudioService[payload.method];
      if (typeof method !== "function") {
        throw new Error(`Unknown desktop native audio method ${payload.method}`);
      }

      return (method as DesktopNativeAudioServiceMethod)(...payload.args);
    },
  );
}

export function sendDesktopNativeAudioEvent<TEvent extends NativeAudioEventName>(
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
