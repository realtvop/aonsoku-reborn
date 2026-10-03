import type { BrowserWindow } from "electron";
import { ipcMain } from "electron";
import { desktopNativeAudioService } from "../audio/ipc";
import { desktopNativeBridgeService } from "../bridge/ipc";
import { getDesktopNativeDataService } from "../data/ipc";
import { DesktopNativeCoordinationService } from "./service";

export const DESKTOP_NATIVE_COORDINATION_CHANNEL =
  "aonsoku-native-coordination";
export const DESKTOP_NATIVE_COORDINATION_EVENT_CHANNEL =
  "aonsoku-native-coordination-event";
let coordinationService: DesktopNativeCoordinationService | null = null;

export function setupDesktopNativeCoordinationIpc(window: BrowserWindow): void {
  coordinationService?.destroy().catch(() => {});
  const service = new DesktopNativeCoordinationService(
    (event, payload) => {
      if (!window.isDestroyed())
        window.webContents.send(
          DESKTOP_NATIVE_COORDINATION_EVENT_CHANNEL,
          event,
          payload,
        );
    },
    desktopNativeAudioService.getNativePlaybackCapability().available
      ? {
          audio: desktopNativeAudioService,
          request: (options) => desktopNativeBridgeService.request(options),
          cachedSongs: () =>
            getDesktopNativeDataService()
              ?.getSongs({ offset: 0, limit: 100_000 })
              .items.map((song) => ({ ...song })) ?? [],
        }
      : undefined,
  );
  coordinationService = service;
  ipcMain.removeHandler(DESKTOP_NATIVE_COORDINATION_CHANNEL);
  ipcMain.handle(
    DESKTOP_NATIVE_COORDINATION_CHANNEL,
    (_event, method: string, args: unknown[]) => {
      const callable =
        service[method as keyof DesktopNativeCoordinationService];
      if (typeof callable !== "function")
        throw new Error(`Unsupported native coordination method: ${method}`);
      return Reflect.apply(callable, service, args);
    },
  );
}

export async function destroyDesktopNativeCoordinationService(): Promise<void> {
  ipcMain.removeHandler(DESKTOP_NATIVE_COORDINATION_CHANNEL);
  await coordinationService?.destroy();
  coordinationService = null;
}
