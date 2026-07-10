import { ElectronAPI } from "@electron-toolkit/preload";
import type { AonsokuAudioBridge } from "@aonsoku/audio-contract";
import type { AonsokuNativeBridgePlugin } from "@aonsoku/capacitor-native/bridge";
import type { AonsokuNativeCoordinationPlugin } from "@aonsoku/capacitor-native/coordination";
import type { AonsokuNativeDataPlugin } from "@aonsoku/capacitor-native/data";
import type { AonsokuNativePreferencesPlugin } from "@aonsoku/capacitor-native/preferences";
import { IAonsokuAPI } from "../../electron/preload/types";

export {};

declare global {
  interface Window {
    electron: ElectronAPI;
    api: IAonsokuAPI;
    aonsokuNativeAudio?: AonsokuAudioBridge;
    aonsokuNativeBridge?: AonsokuNativeBridgePlugin;
    aonsokuNativeData?: AonsokuNativeDataPlugin;
    aonsokuNativePreferences?: AonsokuNativePreferencesPlugin;
    aonsokuNativeCoordination?: AonsokuNativeCoordinationPlugin;
  }
}
