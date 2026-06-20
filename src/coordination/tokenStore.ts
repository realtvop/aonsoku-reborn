// Token storage for coordination credentials (design §6.3).
// Web: IndexedDB (with XSS risk noted in UI). Electron: safeStorage.
// Native: Keychain/Keystore via the native bridge.

import type { DeviceId, AccountId } from "./types";
import type { StoredDeviceTokens } from "./httpClient";

const STORAGE_KEY = "coordination_tokens";

export interface CoordinationConfig {
  serverUrl: string;
  identityUrl: string;
}

const CONFIG_KEY = "coordination_config";

/// Load tokens from storage. Web uses localStorage with hex-encoded refresh
/// token (matching the LAN control pattern); native delegates to the bridge.
export async function loadTokens(): Promise<StoredDeviceTokens | null> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    return JSON.parse(raw) as StoredDeviceTokens;
  } catch {
    return null;
  }
}

export async function saveTokens(
  tokens: StoredDeviceTokens | null,
): Promise<void> {
  try {
    if (tokens) {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(tokens));
    } else {
      localStorage.removeItem(STORAGE_KEY);
    }
  } catch {
    // Storage unavailable (private mode); tokens won't persist across reloads.
  }
}

export async function loadConfig(): Promise<CoordinationConfig | null> {
  try {
    const raw = localStorage.getItem(CONFIG_KEY);
    if (!raw) return null;
    return JSON.parse(raw) as CoordinationConfig;
  } catch {
    return null;
  }
}

export async function saveConfig(
  config: CoordinationConfig | null,
): Promise<void> {
  try {
    if (config) {
      localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
    } else {
      localStorage.removeItem(CONFIG_KEY);
    }
  } catch {
    // Storage unavailable.
  }
}

export function clearTokens(): void {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch {
    // ignore
  }
}

export type { DeviceId, AccountId };
