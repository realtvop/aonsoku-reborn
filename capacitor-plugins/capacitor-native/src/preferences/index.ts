import { registerPlugin } from "@capacitor/core";
import type { AonsokuNativePreferencesPlugin } from "./definitions";
import { NATIVE_PREFERENCES_PLUGIN_NAME } from "./definitions";
import { AonsokuNativePreferencesWeb } from "./web";

export const AonsokuNativePreferences =
  registerPlugin<AonsokuNativePreferencesPlugin>(
    NATIVE_PREFERENCES_PLUGIN_NAME,
    {
      web: () => new AonsokuNativePreferencesWeb(),
    },
  );

export { NATIVE_PREFERENCES_PLUGIN_NAME };
export { AonsokuNativePreferencesWeb } from "./web";
export type {
  AonsokuNativePreferencesPlugin,
  NativePreferencesChangedEvent,
} from "./definitions";
