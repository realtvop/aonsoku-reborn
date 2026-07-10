import {
  AonsokuNativePreferences as CapacitorNativePreferences,
  NATIVE_PREFERENCES_PLUGIN_NAME,
  type AonsokuNativePreferencesPlugin,
} from "@aonsoku/capacitor-native/preferences";
import { Capacitor } from "@capacitor/core";

export type NativePreferencesAvailability =
  | { available: true; plugin: AonsokuNativePreferencesPlugin }
  | { available: false; reason: string };

export function getNativePreferencesAvailability(): NativePreferencesAvailability {
  if (
    typeof window !== "undefined" &&
    window.aonsokuNativePreferences !== undefined
  ) {
    return { available: true, plugin: window.aonsokuNativePreferences };
  }

  if (!Capacitor.isNativePlatform()) {
    return {
      available: false,
      reason: "Only supported on native Capacitor platforms",
    };
  }

  const platform = Capacitor.getPlatform();
  if (platform !== "ios" && platform !== "android") {
    return {
      available: false,
      reason: `Unsupported native platform: ${platform}`,
    };
  }

  if (!Capacitor.isPluginAvailable(NATIVE_PREFERENCES_PLUGIN_NAME)) {
    return {
      available: false,
      reason: "Native preferences plugin is not installed",
    };
  }

  return { available: true, plugin: CapacitorNativePreferences };
}

export function isNativePreferencesAvailable(): boolean {
  return getNativePreferencesAvailability().available;
}

export function getNativePreferences(): AonsokuNativePreferencesPlugin {
  const availability = getNativePreferencesAvailability();
  if (!availability.available) {
    throw new Error(availability.reason);
  }
  return availability.plugin;
}

export const AonsokuNativePreferences = new Proxy(
  {} as AonsokuNativePreferencesPlugin,
  {
    get: (_target, property) => {
      const plugin = getNativePreferences() as unknown as Record<
        PropertyKey,
        unknown
      >;
      const value = plugin[property];
      return typeof value === "function" ? value.bind(plugin) : value;
    },
  },
);

export type { AonsokuNativePreferencesPlugin };
