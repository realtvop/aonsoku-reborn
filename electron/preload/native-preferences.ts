import type { AonsokuNativePreferencesPlugin } from "@aonsoku/capacitor-native/preferences";
import { ipcRenderer } from "electron";

const DESKTOP_NATIVE_PREFERENCES_CHANNEL = "aonsoku-native-preferences";

function invoke<T>(method: string, options?: unknown): Promise<T> {
  return ipcRenderer.invoke(
    DESKTOP_NATIVE_PREFERENCES_CHANNEL,
    method,
    options,
  );
}

export const aonsokuNativePreferences: AonsokuNativePreferencesPlugin = {
  getAllPreferences: () => invoke("getAllPreferences"),
  setPreferences: (options) => invoke("setPreferences", options),
  setPreference: (options) => invoke("setPreference", options),
  deletePreference: (options) => invoke("deletePreference", options),
  getQueueState: () => invoke("getQueueState"),
  setQueueState: (options) => invoke("setQueueState", options),
  getPlayHistory: (options) => invoke("getPlayHistory", options),
  addToPlayHistory: (options) => invoke("addToPlayHistory", options),
  clearPlayHistory: () => invoke("clearPlayHistory"),
  addListener: async () => ({ remove: async () => {} }),
  removeAllListeners: async () => {},
};
