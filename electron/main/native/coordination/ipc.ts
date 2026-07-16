import type { BrowserWindow } from "electron";
import { ipcMain } from "electron";
import { DesktopNativeCoordinationService } from "./service";

export const DESKTOP_NATIVE_COORDINATION_CHANNEL =
  "aonsoku-native-coordination";
export const DESKTOP_NATIVE_COORDINATION_EVENT_CHANNEL =
  "aonsoku-native-coordination-event";

export function setupDesktopNativeCoordinationIpc(window: BrowserWindow): void {
  const service = new DesktopNativeCoordinationService((event, payload) => {
    if (!window.isDestroyed())
      window.webContents.send(
        DESKTOP_NATIVE_COORDINATION_EVENT_CHANNEL,
        event,
        payload,
      );
  });
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
