import { ipcMain } from "electron";
import { DesktopNativeBridgeService } from "./service";

export const DESKTOP_NATIVE_BRIDGE_CHANNEL = "aonsoku-native-bridge";

export const desktopNativeBridgeService = new DesktopNativeBridgeService();

async function resetAccountData(): Promise<void> {
  // Fence network requests before waiting for old transfers to leave the cache.
  desktopNativeBridgeService.clearCredentials();
  const [
    { getDesktopNativeDataService },
    { desktopNativeAudioService },
    { desktopNativePreferencesService },
  ] = await Promise.all([
    import("../data/ipc"),
    import("../audio/ipc"),
    import("../preferences/ipc"),
  ]);
  await Promise.all([
    getDesktopNativeDataService()?.resetAccount(),
    desktopNativeAudioService.resetAccount(),
    desktopNativePreferencesService.clearPlayHistory(),
  ]);
}

export function setupDesktopNativeBridgeIpc(): void {
  ipcMain.removeHandler(DESKTOP_NATIVE_BRIDGE_CHANNEL);
  ipcMain.handle(
    DESKTOP_NATIVE_BRIDGE_CHANNEL,
    async (_event, method, options) => {
      switch (method) {
        case "storeCredentials":
          return desktopNativeBridgeService.storeCredentials(options);
        case "getCredentials":
          return desktopNativeBridgeService.getCredentials();
        case "clearCredentials":
          return resetAccountData();
        case "hasCredentials":
          return desktopNativeBridgeService.hasCredentials();
        case "login":
          await resetAccountData();
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
    },
  );
}
