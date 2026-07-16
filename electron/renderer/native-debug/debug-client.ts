import type {
  NativeDebugControl,
  NativeDebugSnapshot,
} from "../../main/native/debug/types";

/**
 * Thin wrapper over the preload-exposed `window.aonsokuNativeDebug` bridge.
 * Centralizes the IPC calls so components do not touch the global directly and
 * the snapshot shape is typed against the main-process debug types.
 */
export const debugClient = {
  getSnapshot(): Promise<NativeDebugSnapshot> {
    if (!window.aonsokuNativeDebug) {
      return Promise.reject(new Error("Native debug bridge unavailable"));
    }
    return window.aonsokuNativeDebug.getSnapshot();
  },

  control(control: NativeDebugControl): Promise<void> {
    if (!window.aonsokuNativeDebug) return Promise.resolve();
    return window.aonsokuNativeDebug.control(control);
  },

  clearLogs(): Promise<void> {
    if (!window.aonsokuNativeDebug) return Promise.resolve();
    return window.aonsokuNativeDebug.clearLogs();
  },
};
