import { ipcMain } from "electron";
import { DesktopNativePreferencesService } from "./service";

export const DESKTOP_NATIVE_PREFERENCES_CHANNEL = "aonsoku-native-preferences";

export const desktopNativePreferencesService =
  new DesktopNativePreferencesService();

export function setupDesktopNativePreferencesIpc(): void {
  ipcMain.removeHandler(DESKTOP_NATIVE_PREFERENCES_CHANNEL);
  ipcMain.handle(
    DESKTOP_NATIVE_PREFERENCES_CHANNEL,
    (_event, method, options) => {
      switch (method) {
        case "getAllPreferences":
          return desktopNativePreferencesService.getAllPreferences();
        case "setPreferences":
          return desktopNativePreferencesService.setPreferences(options);
        case "setPreference":
          return desktopNativePreferencesService.setPreference(options);
        case "deletePreference":
          return desktopNativePreferencesService.deletePreference(options);
        case "getQueueState":
          return desktopNativePreferencesService.getQueueState();
        case "setQueueState":
          return desktopNativePreferencesService.setQueueState(options);
        case "getPlayHistory":
          return desktopNativePreferencesService.getPlayHistory(options);
        case "addToPlayHistory":
          return desktopNativePreferencesService.addToPlayHistory(options);
        case "clearPlayHistory":
          return desktopNativePreferencesService.clearPlayHistory();
        default:
          throw new Error(`Unsupported native preferences method: ${method}`);
      }
    },
  );
}
