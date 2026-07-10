import { ElectronAPI } from "@electron-toolkit/preload";
import type { AonsokuAudioBridge } from "@aonsoku/audio-contract";
import type { AonsokuNativeBridgePlugin } from "@aonsoku/capacitor-native/bridge";
import { IAonsokuAPI } from "../../electron/preload/types";

export {};

declare global {
  interface Window {
    electron: ElectronAPI;
    api: IAonsokuAPI;
    aonsokuNativeAudio?: AonsokuAudioBridge;
    aonsokuNativeBridge?: AonsokuNativeBridgePlugin;
  }
}
