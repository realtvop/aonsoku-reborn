import { ipcRenderer } from "electron";
import type {
  NativeDebugControl,
  NativeDebugSnapshot,
} from "../main/native/debug/types";

const SNAPSHOT_CHANNEL = "aonsoku-native-debug:snapshot";
const CONTROL_CHANNEL = "aonsoku-native-debug:control";
const CLEAR_LOGS_CHANNEL = "aonsoku-native-debug:clear-logs";

export interface AonsokuNativeDebugApi {
  getSnapshot: () => Promise<NativeDebugSnapshot>;
  control: (control: NativeDebugControl) => Promise<void>;
  clearLogs: () => Promise<void>;
}

export const aonsokuNativeDebug: AonsokuNativeDebugApi = {
  getSnapshot: () => ipcRenderer.invoke(SNAPSHOT_CHANNEL),
  control: (control) => ipcRenderer.invoke(CONTROL_CHANNEL, control),
  clearLogs: () => ipcRenderer.invoke(CLEAR_LOGS_CHANNEL),
};
