import type { AonsokuNativeBridgePlugin } from "@aonsoku/capacitor-native/bridge";
import { ipcRenderer } from "electron";

const DESKTOP_NATIVE_BRIDGE_CHANNEL = "aonsoku-native-bridge";

function invoke<T>(method: string, options?: unknown): Promise<T> {
  return ipcRenderer.invoke(DESKTOP_NATIVE_BRIDGE_CHANNEL, method, options);
}

export const aonsokuNativeBridge: AonsokuNativeBridgePlugin = {
  storeCredentials: (options) => invoke("storeCredentials", options),
  getCredentials: () => invoke("getCredentials"),
  clearCredentials: () => invoke("clearCredentials"),
  hasCredentials: () => invoke("hasCredentials"),
  login: (options) => invoke("login", options),
  ping: (options) => invoke("ping", options),
  queryServerInfo: (options) => invoke("queryServerInfo", options),
  request: (options) => invoke("request", options),
  getMaterialYouColors: async () => ({ supported: false }),
  addListener: async () => ({ remove: async () => {} }),
  removeAllListeners: async () => {},
};
