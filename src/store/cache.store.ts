import merge from "lodash/merge";
import { devtools, persist, subscribeWithSelector } from "zustand/middleware";
import { immer } from "zustand/middleware/immer";
import { shallow } from "zustand/shallow";
import { createWithEqualityFn } from "zustand/traditional";
import { createNativeStorage } from "@/store/native-storage";
import {
  CacheSettings,
  CacheStatus,
  COVER_ART_CONCURRENCY_DEFAULT,
  COVER_ART_CONCURRENCY_MAX,
  COVER_ART_CONCURRENCY_MIN,
  DEFAULT_ASSETS_QUOTA,
  DEFAULT_LRU_QUOTA,
  DEFAULT_MAX_CACHE_SIZE,
  DEFAULT_SMART_RULES,
  SmartRuleSettings,
  SyncState,
} from "@/types/cache";
import { getRuntime } from "@/utils/capabilities";

interface CacheActions {
  setMaxCacheSize: (bytes: number) => void;
  setAssetsQuota: (bytes: number) => void;
  setLruQuota: (bytes: number) => void;
  setSmartRules: (rules: Partial<SmartRuleSettings>) => void;
  setLibraryCaching: (enabled: boolean) => void;
  setSyncCoverArt: (enabled: boolean) => void;
  setCoverArtConcurrency: (concurrency: number) => void;
  setIsOnline: (online: boolean) => void;
  setIsMetered: (metered: boolean) => void;
  updateCacheStats: (stats: {
    audioSize: number;
    coverSize: number;
    audioCount: number;
    coverCount: number;
  }) => void;
  updateSyncState: (syncState: Partial<SyncState>) => void;
  setLastSyncedAt: (timestamp: number | null) => void;
}

interface CacheStoreState {
  settings: CacheSettings;
  status: CacheStatus;
  actions: CacheActions;
}

const defaultSyncState: SyncState = {
  phase: "idle",
  progress: 0,
  isSyncing: false,
  totalItems: 0,
  processedItems: 0,
};

function migrateSettings(persisted: Record<string, unknown>): CacheSettings {
  const isNativeLibraryRuntime = getRuntime() !== "web";
  // Pre-P2.3 format (had maxCacheSize but not the per-pool quotas).
  const raw = persisted as Partial<CacheSettings> | undefined;
  if (raw && typeof raw === "object") {
    const needsQuotaMigration =
      raw.assetsQuota === undefined || raw.lruQuota === undefined;
    if (needsQuotaMigration) {
      const legacyCap =
        typeof raw.maxCacheSize === "number"
          ? raw.maxCacheSize
          : DEFAULT_MAX_CACHE_SIZE;
      return {
        ...(raw as CacheSettings),
        assetsQuota: raw.assetsQuota ?? DEFAULT_ASSETS_QUOTA,
        lruQuota: raw.lruQuota ?? legacyCap,
        smartRules: { ...DEFAULT_SMART_RULES, ...(raw.smartRules ?? {}) },
        libraryCaching: isNativeLibraryRuntime
          ? true
          : (raw.libraryCaching ?? false),
      };
    }
  }

  // Ensure smartRules is always present post-merge even when no other
  // field needed migration.
  const final = persisted as Record<string, unknown>;
  if (final && typeof final === "object" && !final.smartRules) {
    return {
      ...(final as unknown as CacheSettings),
      smartRules: { ...DEFAULT_SMART_RULES },
      libraryCaching: isNativeLibraryRuntime
        ? true
        : final.libraryCaching === true,
    };
  }

  return {
    ...(persisted as unknown as CacheSettings),
    libraryCaching: isNativeLibraryRuntime
      ? true
      : (persisted as Record<string, unknown>).libraryCaching === true,
  };
}

export const useCacheStore = createWithEqualityFn<CacheStoreState>()(
  subscribeWithSelector(
    persist(
      devtools(
        immer((set) => ({
          settings: {
            maxCacheSize: DEFAULT_MAX_CACHE_SIZE,
            assetsQuota: DEFAULT_ASSETS_QUOTA,
            lruQuota: DEFAULT_LRU_QUOTA,
            smartRules: { ...DEFAULT_SMART_RULES },
            libraryCaching: getRuntime() !== "web",
            syncLibrary: true,
            syncCoverArt: false,
            coverArtConcurrency: COVER_ART_CONCURRENCY_DEFAULT,
          },
          status: {
            isOnline: true,
            isMetered: false,
            currentAudioCacheSize: 0,
            currentCoverCacheSize: 0,
            audioCachedCount: 0,
            coverCachedCount: 0,
            syncState: { ...defaultSyncState },
            lastSyncedAt: null,
          },
          actions: {
            setMaxCacheSize: (bytes) => {
              set((state) => {
                state.settings.maxCacheSize = bytes;
              });
            },
            setAssetsQuota: (bytes) => {
              set((state) => {
                state.settings.assetsQuota = bytes;
              });
            },
            setLruQuota: (bytes) => {
              set((state) => {
                state.settings.lruQuota = bytes;
              });
            },
            setSmartRules: (rules) => {
              set((state) => {
                Object.assign(state.settings.smartRules, rules);
              });
            },
            setLibraryCaching: (enabled) => {
              set((state) => {
                const isCapacitorNative =
                  getRuntime() === "capacitor-ios" ||
                  getRuntime() === "capacitor-android";
                const value = isCapacitorNative ? true : enabled;
                state.settings.libraryCaching = value;
                state.settings.syncLibrary = value;
              });
            },
            setSyncCoverArt: (enabled) => {
              set((state) => {
                state.settings.syncCoverArt = enabled;
              });
            },
            setCoverArtConcurrency: (concurrency) => {
              set((state) => {
                state.settings.coverArtConcurrency = Math.min(
                  COVER_ART_CONCURRENCY_MAX,
                  Math.max(COVER_ART_CONCURRENCY_MIN, concurrency),
                );
              });
            },
            setIsOnline: (online) => {
              set((state) => {
                state.status.isOnline = online;
              });
            },
            setIsMetered: (metered) => {
              set((state) => {
                state.status.isMetered = metered;
              });
            },
            updateCacheStats: (stats) => {
              set((state) => {
                state.status.currentAudioCacheSize = stats.audioSize;
                state.status.currentCoverCacheSize = stats.coverSize;
                state.status.audioCachedCount = stats.audioCount;
                state.status.coverCachedCount = stats.coverCount;
              });
            },
            updateSyncState: (syncState) => {
              set((state) => {
                Object.assign(state.status.syncState, syncState);
              });
            },
            setLastSyncedAt: (timestamp) => {
              set((state) => {
                state.status.lastSyncedAt = timestamp;
              });
            },
          },
        })),
        { name: "cache_store" },
      ),
      {
        name: "cache_settings",
        storage: createNativeStorage<CacheStoreState>("cache_settings"),
        partialize: (state) => ({
          settings: state.settings,
          status: {
            lastSyncedAt: state.status.lastSyncedAt,
          },
        }),
        merge: (persisted, current) => {
          const raw = persisted as Record<string, unknown> | null;
          if (!raw) return current;
          const settings = raw.settings as Record<string, unknown> | undefined;
          if (settings) {
            raw.settings = migrateSettings(settings);
          }
          const merged = merge({}, current, raw);
          if (getRuntime() !== "web") {
            merged.settings.libraryCaching = true;
            merged.settings.syncLibrary = true;
          }
          return merged;
        },
      },
    ),
  ),
  shallow,
);

export const useCacheSettings = () => useCacheStore((state) => state.settings);

export const useSmartRules = () =>
  useCacheStore((state) => state.settings.smartRules);

export const useCacheStatus = () => useCacheStore((state) => state.status);

export const useCacheStats = () =>
  useCacheStore(
    (state) => ({
      audioSize: state.status.currentAudioCacheSize,
      coverSize: state.status.currentCoverCacheSize,
      audioCount: state.status.audioCachedCount,
      coverCount: state.status.coverCachedCount,
    }),
    shallow,
  );

export const useIsOnline = () =>
  useCacheStore((state) => state.status.isOnline);

export const useIsMetered = () =>
  useCacheStore((state) => state.status.isMetered);

/** "unmetered" | "metered" | "offline" */
export const useNetworkTier = () =>
  useCacheStore((state) => {
    if (!state.status.isOnline) return "offline" as const;
    return state.status.isMetered
      ? ("metered" as const)
      : ("unmetered" as const);
  });

export const useIsOfflineMode = () =>
  useCacheStore((state) => !state.status.isOnline);

export const useSyncState = () =>
  useCacheStore((state) => state.status.syncState);

export const useLastSyncedAt = () =>
  useCacheStore((state) => state.status.lastSyncedAt);

export const useCacheActions = () => useCacheStore((state) => state.actions);

export const useLibraryCaching = () =>
  useCacheStore((state) => {
    if (
      getRuntime() === "capacitor-ios" ||
      getRuntime() === "capacitor-android"
    )
      return true;
    return state.settings.libraryCaching;
  });
