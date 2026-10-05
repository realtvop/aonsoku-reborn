import type { Plugin } from "@capacitor/core";

export const NATIVE_PREFERENCES_PLUGIN_NAME = "AonsokuNativePreferences";

export interface NativePreferencesChangedEvent {
  key?: string;
  value?: string;
  preferences: Record<string, string>;
}

export interface AonsokuNativePreferencesPlugin extends Plugin {
  getAllPreferences(): Promise<{ preferences: Record<string, string> }>;
  setPreferences(options: {
    preferences: Record<string, string>;
  }): Promise<void>;
  setPreference(options: { key: string; value: string }): Promise<void>;
  deletePreference(options: { key: string }): Promise<void>;
  getQueueState(): Promise<{ state: string | null }>;
  setQueueState(options: { state: string }): Promise<void>;
  getPlayHistory(options?: { limit?: number }): Promise<{ history: string[] }>;
  addToPlayHistory(options: { song: string; maxSize?: number }): Promise<void>;
  clearPlayHistory(): Promise<void>;
}
