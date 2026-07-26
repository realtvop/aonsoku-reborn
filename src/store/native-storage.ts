import type { AonsokuNativePreferencesPlugin } from "@aonsoku/capacitor-native/preferences";
import type { PersistStorage, StorageValue } from "zustand/middleware";
import {
  getNativePreferences,
  isNativePreferencesAvailable,
} from "@/native/preferences/facade";

let nativePrefsCache: Record<string, string> | null = null;
let cacheReady = false;
let pluginRef: AonsokuNativePreferencesPlugin | null = null;
let initializationPromise: Promise<void> | null = null;
const pendingReads: Array<() => void> = [];

export function initNativePrefsCache(): Promise<void> {
  if (!isNativePreferencesAvailable()) return Promise.resolve();
  if (initializationPromise) return initializationPromise;

  const plugin = getNativePreferences();
  pluginRef = plugin;

  initializationPromise = (async () => {
    try {
      const { migrateToNativeStorageIfNeeded } = await import(
        "@/store/native-migration"
      );
      nativePrefsCache = await migrateToNativeStorageIfNeeded(plugin);
    } catch (error) {
      nativePrefsCache = {};
      console.error("[native-storage] failed to initialize preferences", error);
    } finally {
      cacheReady = true;
      for (const resolve of pendingReads) resolve();
      pendingReads.length = 0;
    }
  })();

  return initializationPromise;
}

export function isNativeStorageReady(): boolean {
  return cacheReady;
}

export function getNativePrefsPlugin(): AonsokuNativePreferencesPlugin | null {
  return pluginRef;
}

export function getPreferenceValue(key: string): string | null {
  if (!isNativePreferencesAvailable()) {
    return localStorage.getItem(key);
  }

  return nativePrefsCache?.[key] ?? null;
}

export function setPreferenceValue(key: string, value: string): void {
  if (!isNativePreferencesAvailable()) {
    localStorage.setItem(key, value);
    return;
  }

  if (nativePrefsCache) {
    nativePrefsCache[key] = value;
  }
  debouncedNativeWrite(key, value);
}

export function removePreferenceValue(key: string): void {
  if (!isNativePreferencesAvailable()) {
    localStorage.removeItem(key);
    return;
  }

  if (nativePrefsCache) {
    delete nativePrefsCache[key];
  }
  pluginRef?.deletePreference({ key });
}

const writeTimers = new Map<string, ReturnType<typeof setTimeout>>();
const WRITE_DEBOUNCE_MS = 300;

function debouncedNativeWrite(key: string, value: string) {
  const existing = writeTimers.get(key);
  if (existing) clearTimeout(existing);

  writeTimers.set(
    key,
    setTimeout(() => {
      writeTimers.delete(key);
      pluginRef?.setPreference({ key, value });
    }, WRITE_DEBOUNCE_MS),
  );
}

export function flushNativeWrites(): void {
  if (writeTimers.size === 0 || !pluginRef) return;
  const batch: Record<string, string> = {};
  for (const [key, timer] of writeTimers) {
    clearTimeout(timer);
    const value = nativePrefsCache?.[key];
    if (value != null) {
      batch[key] = value;
    }
  }
  writeTimers.clear();
  if (Object.keys(batch).length > 0) {
    pluginRef.setPreferences({ preferences: batch });
  }
}

export function createNativeStorage<S>(storeName: string): PersistStorage<S> {
  if (!isNativePreferencesAvailable()) {
    return {
      getItem: (name: string) => {
        const str = localStorage.getItem(name);
        return str ? (JSON.parse(str) as StorageValue<S>) : null;
      },
      setItem: (name: string, value: StorageValue<S>) => {
        localStorage.setItem(name, JSON.stringify(value));
      },
      removeItem: (name: string) => {
        localStorage.removeItem(name);
      },
    };
  }

  return {
    getItem: (_name: string) => {
      if (!cacheReady) {
        return new Promise<StorageValue<S> | null>((resolve) => {
          pendingReads.push(() => {
            const raw = nativePrefsCache?.[storeName];
            if (!raw) {
              resolve(null);
              return;
            }
            try {
              resolve(JSON.parse(raw) as StorageValue<S>);
            } catch {
              resolve(null);
            }
          });
        });
      }

      const raw = nativePrefsCache?.[storeName];
      if (!raw) return null;
      try {
        return JSON.parse(raw) as StorageValue<S>;
      } catch {
        return null;
      }
    },

    setItem: (_name: string, value: StorageValue<S>) => {
      const serialized = JSON.stringify(value);
      if (nativePrefsCache) {
        nativePrefsCache[storeName] = serialized;
      }
      debouncedNativeWrite(storeName, serialized);
    },

    removeItem: (_name: string) => {
      if (nativePrefsCache) {
        delete nativePrefsCache[storeName];
      }
      pluginRef?.deletePreference({ key: storeName });
    },
  };
}
