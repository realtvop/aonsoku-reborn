import {
  type AonsokuNativeDataPlugin,
  AonsokuNativeData as CapacitorNativeData,
  NATIVE_DATA_PLUGIN_NAME,
} from "@aonsoku/capacitor-native/data";
import { Capacitor } from "@capacitor/core";

export type NativeDataAvailability =
  | { available: true; plugin: AonsokuNativeDataPlugin }
  | { available: false; reason: string };

const NATIVE_DATA_PLATFORMS = ["ios", "android"];

export function getNativeDataAvailability(): NativeDataAvailability {
  if (typeof window !== "undefined" && window.aonsokuNativeData !== undefined) {
    return { available: true, plugin: window.aonsokuNativeData };
  }

  if (
    !Capacitor.isNativePlatform() ||
    !NATIVE_DATA_PLATFORMS.includes(Capacitor.getPlatform())
  ) {
    return {
      available: false,
      reason: "Only supported in Capacitor iOS and Android",
    };
  }

  if (!Capacitor.isPluginAvailable(NATIVE_DATA_PLUGIN_NAME)) {
    return {
      available: false,
      reason: "Native data plugin is not installed",
    };
  }

  return { available: true, plugin: CapacitorNativeData };
}

export function isNativeDataAvailable(): boolean {
  return getNativeDataAvailability().available;
}

export function getNativeData(): AonsokuNativeDataPlugin {
  const availability = getNativeDataAvailability();
  if (!availability.available) throw new Error(availability.reason);
  return availability.plugin;
}

export const AonsokuNativeData = new Proxy({} as AonsokuNativeDataPlugin, {
  get: (_target, property) => {
    const plugin = getNativeData() as unknown as Record<PropertyKey, unknown>;
    const value = plugin[property];
    return typeof value === "function" ? value.bind(plugin) : value;
  },
});
export type { AonsokuNativeDataPlugin } from "@aonsoku/capacitor-native/data";
