import { ipcMain } from "electron";
import {
  applyNativeDebugControl,
  clearNativeDebugLogs,
  getNativeDebugSnapshot,
} from "./debug-provider";
import type { NativeDebugControl } from "./types";

export const DESKTOP_NATIVE_DEBUG_SNAPSHOT_CHANNEL =
  "aonsoku-native-debug:snapshot";
export const DESKTOP_NATIVE_DEBUG_CONTROL_CHANNEL =
  "aonsoku-native-debug:control";
export const DESKTOP_NATIVE_DEBUG_CLEAR_LOGS_CHANNEL =
  "aonsoku-native-debug:clear-logs";

/**
 * Register the native player debug IPC handlers. Safe to call multiple times —
 * existing handlers are removed first. The window-open entry point lives in the
 * general app IPC (`IpcChannels.OpenNativeDebug`) because it is invoked from
 * the macOS application menu, not from the debug renderer itself.
 */
export function setupDesktopNativeDebugIpc(): void {
  ipcMain.removeHandler(DESKTOP_NATIVE_DEBUG_SNAPSHOT_CHANNEL);
  ipcMain.removeHandler(DESKTOP_NATIVE_DEBUG_CONTROL_CHANNEL);
  ipcMain.removeHandler(DESKTOP_NATIVE_DEBUG_CLEAR_LOGS_CHANNEL);

  ipcMain.handle(DESKTOP_NATIVE_DEBUG_SNAPSHOT_CHANNEL, () =>
    getNativeDebugSnapshot(),
  );
  ipcMain.handle(
    DESKTOP_NATIVE_DEBUG_CONTROL_CHANNEL,
    (_event, control: NativeDebugControl) => applyNativeDebugControl(control),
  );
  ipcMain.handle(DESKTOP_NATIVE_DEBUG_CLEAR_LOGS_CHANNEL, () =>
    clearNativeDebugLogs(),
  );
}

export function destroyDesktopNativeDebugIpc(): void {
  ipcMain.removeHandler(DESKTOP_NATIVE_DEBUG_SNAPSHOT_CHANNEL);
  ipcMain.removeHandler(DESKTOP_NATIVE_DEBUG_CONTROL_CHANNEL);
  ipcMain.removeHandler(DESKTOP_NATIVE_DEBUG_CLEAR_LOGS_CHANNEL);
}
