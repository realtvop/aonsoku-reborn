import {
  AonsokuNativeBridge,
  type AonsokuNativeBridgePlugin,
  NATIVE_BRIDGE_PLUGIN_NAME,
} from "@aonsoku/capacitor-native/bridge";
import { Capacitor } from "@capacitor/core";

export type NativeBridgeAvailability =
  | { available: true; plugin: AonsokuNativeBridgePlugin }
  | { available: false; reason: string };

export function getNativeBridgeAvailability(): NativeBridgeAvailability {
  if (
    typeof window !== "undefined" &&
    window.aonsokuNativeBridge !== undefined
  ) {
    return { available: true, plugin: window.aonsokuNativeBridge };
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

  if (!Capacitor.isPluginAvailable(NATIVE_BRIDGE_PLUGIN_NAME)) {
    return {
      available: false,
      reason: "Native bridge plugin is not installed",
    };
  }

  return { available: true, plugin: AonsokuNativeBridge };
}

export function isNativeBridgeAvailable(): boolean {
  return getNativeBridgeAvailability().available;
}

export function getNativeBridge(): AonsokuNativeBridgePlugin {
  const availability = getNativeBridgeAvailability();
  if (!availability.available) {
    throw new Error(availability.reason);
  }
  return availability.plugin;
}

export type {
  AonsokuNativeBridgePlugin,
  LoginOptions,
  LoginResult,
  MaterialYouColors,
  MaterialYouColorsResult,
  StoredCredentials,
} from "@aonsoku/capacitor-native/bridge";
export { AonsokuNativeBridge } from "@aonsoku/capacitor-native/bridge";
