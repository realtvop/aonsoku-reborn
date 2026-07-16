import { ipcMain } from "electron";
import { DesktopNativeBridgeService } from "./service";

export const DESKTOP_NATIVE_BRIDGE_CHANNEL = "aonsoku-native-bridge";

export const desktopNativeBridgeService = new DesktopNativeBridgeService();

export function setupDesktopNativeBridgeIpc(): void {
  ipcMain.removeHandler(DESKTOP_NATIVE_BRIDGE_CHANNEL);
  ipcMain.handle(DESKTOP_NATIVE_BRIDGE_CHANNEL, (_event, method, options) => {
    switch (method) {
      case "storeCredentials":
        return desktopNativeBridgeService.storeCredentials(options);
      case "getCredentials":
        return desktopNativeBridgeService.getCredentials();
      case "clearCredentials":
        return desktopNativeBridgeService.clearCredentials();
      case "hasCredentials":
        return desktopNativeBridgeService.hasCredentials();
      case "login":
        return desktopNativeBridgeService.login(options);
      case "ping":
        return desktopNativeBridgeService.ping(options);
      case "queryServerInfo":
        return desktopNativeBridgeService.queryServerInfo(options);
      case "request":
        return desktopNativeBridgeService.request(options);
      default:
        throw new Error(`Unsupported native bridge method: ${method}`);
    }
  });
}
