import {
  getNativePreferences,
  isNativePreferencesAvailable,
} from "@/native/preferences/facade";

export const ACCOUNT_RESET_KEY = "aonsoku.account-reset.v1";
const DATABASES = [
  "aonsoku-library",
  "aonsoku-cache",
  "aonsoku-offline",
  "aonsoku-custom-lyrics",
  "keyval-store",
];
const PRIVATE_PREFERENCES = [
  "pinned_home_store",
  "player_history",
  "albums-list-artist-id",
  "albums-list-artist-name",
  "albums-list-genre",
  "albums-list-year",
  "albums-list-filter",
];

export async function markAccountReset(): Promise<void> {
  const { flushNativeWrites } = await import("@/store/native-storage");
  await flushNativeWrites();
  localStorage.setItem(ACCOUNT_RESET_KEY, crypto.randomUUID());
}

export function resetAccountPreferences(
  key: string,
  raw: string,
): string | null {
  if (PRIVATE_PREFERENCES.includes(key)) return null;
  if (!["player_store", "cache_settings", "app_store"].includes(key))
    return raw;
  try {
    const value = JSON.parse(raw);
    if (key === "player_store") {
      const settings = value.state?.settings ?? {};
      if (settings.lyrics) settings.lyrics.selectedCustomLyrics = {};
      if (settings.colors) settings.colors.currentSongColor = null;
      value.state = { settings };
    } else if (key === "cache_settings") {
      value.state.status = { lastSyncedAt: null };
    } else if (value.state?.data) {
      value.state.data.songCount = null;
      value.state.data.favoriteCount = null;
    }
    return JSON.stringify(value);
  } catch {
    // An unreadable private store must not be adopted by the next account.
    return null;
  }
}

function deleteDatabase(name: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(name);
    const timer = setTimeout(
      () => reject(new Error(`Account cleanup blocked: ${name}`)),
      10_000,
    );
    request.onsuccess = () => {
      clearTimeout(timer);
      resolve();
    };
    request.onerror = () => {
      clearTimeout(timer);
      reject(request.error);
    };
  });
}

/** Runs before stores, workers or the router are imported. Retry after a crash. */
export async function finishAccountReset(): Promise<void> {
  const pending = localStorage.getItem(ACCOUNT_RESET_KEY);
  if (!pending) return;
  const native = isNativePreferencesAvailable() ? getNativePreferences() : null;
  const localKeys = Array.from(
    { length: localStorage.length },
    (_, i) => localStorage.key(i)!,
  ).filter(Boolean);
  const preferences = native
    ? (await native.getAllPreferences()).preferences
    : Object.fromEntries(
        localKeys.map((key) => [key, localStorage.getItem(key)!]),
      );
  for (const [key, raw] of Object.entries(preferences)) {
    const next = resetAccountPreferences(key, raw);
    if (next === raw) continue;
    if (native) {
      if (next === null) await native.deletePreference({ key });
      else await native.setPreference({ key, value: next });
    } else if (next === null) localStorage.removeItem(key);
    else localStorage.setItem(key, next);
  }
  if (native) {
    await native.setQueueState({ state: "{}" });
    await native.clearPlayHistory();
  }
  await Promise.all(DATABASES.map(deleteDatabase));
  if (typeof caches !== "undefined") await caches.delete("aonsoku-media-cache");
  if (localStorage.getItem(ACCOUNT_RESET_KEY) === pending)
    localStorage.removeItem(ACCOUNT_RESET_KEY);
}

export async function restartAccountSession(route: string): Promise<void> {
  const { flushNativeWrites } = await import("@/store/native-storage");
  await flushNativeWrites();
  window.location.replace(`${window.location.href.split("#")[0]}#${route}`);
  window.location.reload();
}
