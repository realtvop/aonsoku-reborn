import type { BrowserWindow } from "electron";
import { ipcMain } from "electron";
import { desktopNativeBridgeService } from "../bridge/ipc";
import { DesktopNativeDataService } from "./service";

export const DESKTOP_NATIVE_DATA_CHANNEL = "aonsoku-native-data";
export const DESKTOP_NATIVE_DATA_EVENT_CHANNEL = "aonsoku-native-data-event";

let desktopNativeDataService: DesktopNativeDataService | null = null;

export function getDesktopNativeDataService(): DesktopNativeDataService | null {
  return desktopNativeDataService;
}

export function setupDesktopNativeDataIpc(window: BrowserWindow): void {
  const service = new DesktopNativeDataService(
    desktopNativeBridgeService,
    (event, payload) => {
      if (!window.isDestroyed())
        window.webContents.send(
          DESKTOP_NATIVE_DATA_EVENT_CHANNEL,
          event,
          payload,
        );
    },
  );
  desktopNativeDataService = service;
  ipcMain.removeHandler(DESKTOP_NATIVE_DATA_CHANNEL);
  ipcMain.handle(
    DESKTOP_NATIVE_DATA_CHANNEL,
    (_event, method: string, options) => {
      const callable = service[method as keyof DesktopNativeDataService];
      if (typeof callable !== "function")
        throw new Error(`Unsupported native data method: ${method}`);
      return Reflect.apply(
        callable,
        service,
        options === undefined ? [] : [options],
      );
    },
  );
}
