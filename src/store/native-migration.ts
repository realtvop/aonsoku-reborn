import type { AonsokuNativePreferencesPlugin } from "@aonsoku/capacitor-native/preferences";
import { isNativePreferencesAvailable } from "@/native/preferences/facade";
import { logger } from "@/utils/logger";

const MIGRATED_KEY = "__native_storage_migrated__";

export async function migrateToNativeStorageIfNeeded(
  plugin: AonsokuNativePreferencesPlugin,
): Promise<Record<string, string>> {
  if (!isNativePreferencesAvailable()) return {};

  const { preferences } = await plugin.getAllPreferences();
  if (
    Object.keys(preferences).length > 0 ||
    localStorage.getItem(MIGRATED_KEY) === "1"
  ) {
    localStorage.setItem(MIGRATED_KEY, "1");
    return preferences;
  }

  const storeNames = [
    "app_store",
    "player_store",
    "cache_settings",
    "theme_store",
    "lang_store",
    "ui_store",
    "lan_control_store",
    "albums-list-filter",
    "albums-list-year",
    "albums-list-genre",
    "albums-list-artist-id",
    "albums-list-artist-name",
    "i18nextLng",
  ];

  const migrationPayload: Record<string, string> = {};

  for (const name of storeNames) {
    const raw = localStorage.getItem(name);
    if (raw) {
      migrationPayload[name] = raw;
    }
  }

  for (let index = 0; index < localStorage.length; index += 1) {
    const key = localStorage.key(index);
    if (!key || !key.startsWith("grid_")) continue;
    const raw = localStorage.getItem(key);
    if (raw) {
      migrationPayload[key] = raw;
    }
  }

  try {
    const { get: idbGet } = await import("idb-keyval");
    const songlist = await idbGet("player_songlist");
    if (songlist) {
      await plugin.setQueueState({
        state: JSON.stringify(songlist),
      });
    }

    const history = await idbGet("player_history");
    if (history) {
      migrationPayload.player_history = JSON.stringify(history);
    }
  } catch (err) {
    logger.error("Failed to read IDB during migration", err);
  }

  if (Object.keys(migrationPayload).length > 0) {
    await plugin.setPreferences({ preferences: migrationPayload });
  }

  for (const name of storeNames) {
    localStorage.removeItem(name);
  }
  for (const key of Object.keys(migrationPayload)) {
    if (key.startsWith("grid_")) {
      localStorage.removeItem(key);
    }
  }

  localStorage.setItem(MIGRATED_KEY, "1");
  logger.info(
    `[native-migration] Migrated ${Object.keys(migrationPayload).length} stores to native storage`,
  );
  return migrationPayload;
}
