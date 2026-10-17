/**
 * Why a cached item exists. Determines eviction eligibility:
 * Why a cached item exists. Determines eviction eligibility:
 *
 *  - "explicit" — user pressed "Download" on a song / album / playlist.
 *    Never auto-evicted; only removed by explicit user action.
 *  - "smart"    — a smart-download rule (P5) matched the item. Evicted
 *    the moment no rule still matches it.
 *  - "lru"      — opportunistically cached by playback or queue
 *    prefetch. Evicted oldest-first when the LRU pool is over quota.
 */
export type CacheMetaSource = "explicit" | "smart" | "lru";

export interface SmartRuleSettings {
  /** Master switch — when false the engine does nothing. */
  enabled: boolean;
  favoriteSongs: boolean;
  favoritePlaylists: boolean;
}

export const DEFAULT_SMART_RULES: SmartRuleSettings = {
  enabled: false,
  favoriteSongs: true,
  favoritePlaylists: true,
};

export interface CachedItemMeta {
  id: string;
  type: "audio" | "cover" | "album" | "playlist";
  source: CacheMetaSource;
  /**
   * Rule names (smart-download only) that currently keep this item
   * cached. Cleared when the last rule stops matching, at which point
   * the entry is evicted.
   */
  triggers?: string[];
  /** For cover entries: the resolution (e.g. "700") that was requested. */
  coverSize?: string;
  /** Stable content revision for a cached cover. Changes only on publication. */
  revision?: string;
  sizeBytes: number;
  cachedAt: number;
  lastAccessedAt: number;
  /**
   * True when a synced explicit download no longer exists on the
   * server (P7.3). The local blob is kept so offline playback stays
   * working, but the UI labels it as "removed from server".
   */
  removedFromServer?: boolean;
}

export type SyncTier = "t1" | "t2" | "t3";

export type SyncPhase =
  | "idle"
  | "genres"
  | "artists"
  | "playlists"
  | "albums"
  | "songs"
  | "favorites"
  | "coverArt"
  | "done"
  | "error"
  | "cancelled";

export interface SyncState {
  phase: SyncPhase;
  /** Which tier is currently running, if any. */
  tier?: SyncTier;
  progress: number;
  isSyncing: boolean;
  totalItems: number;
  processedItems: number;
}

export interface CacheSettings {
  /**
   * @deprecated Replaced by `assetsQuota` + `lruQuota` in P2.3.
   * Kept in the type so the cache-store migration can read the old
   * value one time; new code must consume the per-pool quotas.
   */
  maxCacheSize: number;
  /** Cap for L2 resources: cover art (and lyrics once P7.2 lands). */
  assetsQuota: number;
  /** Cap for the LRU audio pool (implicit playback/queue prefetch). */
  lruQuota: number;
  /** P5: automatic-download rules. */
  smartRules: SmartRuleSettings;
  libraryCaching: boolean;
  syncLibrary: boolean;
  syncCoverArt: boolean;
  /** Number of parallel downloads for cover art sync (1 = sequential, 4 = default, 8 = max). */
  coverArtConcurrency: number;
}

export interface CacheStatus {
  isOnline: boolean;
  /**
   * True when the current connection looks expensive or slow
   * (Network Information API: `saveData=true`, `type=cellular`, or
   * `effectiveType` ∈ {slow-2g, 2g, 3g}). Background sync and the
   * smart-download engine back off when this is true; user-initiated
   * downloads are unaffected. Always false on browsers that don't
   * expose the Network Information API.
   */
  isMetered: boolean;
  currentAudioCacheSize: number;
  currentCoverCacheSize: number;
  audioCachedCount: number;
  coverCachedCount: number;
  syncState: SyncState;
  lastSyncedAt: number | null;
}

/**
 * Quota options shared by every per-pool selector. `0` is rendered
 * as "Unlimited".
 */
export const CACHE_SIZE_OPTIONS = [
  { value: 268_435_456, label: "256 MB" },
  { value: 536_870_912, label: "512 MB" },
  { value: 1_073_741_824, label: "1 GB" },
  { value: 2_147_483_648, label: "2 GB" },
  { value: 3_221_225_472, label: "3 GB" },
  { value: 5_368_709_120, label: "5 GB" },
  { value: 0, label: "Unlimited" },
] as const;

/** Legacy single-cap default. Still exported for backwards compat. */
export const DEFAULT_MAX_CACHE_SIZE = 2_147_483_648; // 2 GB
export const DEFAULT_ASSETS_QUOTA = 536_870_912; // 512 MB
export const DEFAULT_LRU_QUOTA = 1_073_741_824; // 1 GB

export const COVER_ART_CONCURRENCY_MIN = 1;
export const COVER_ART_CONCURRENCY_DEFAULT = 4;
export const COVER_ART_CONCURRENCY_MAX = 8;

/**
 * Audio download priority — higher values preempt lower ones in the
 * global AudioCacheQueue.
 */
export const Priority = {
  Playback: 2,
  Explicit: 1,
  Background: 0,
} as const;

export type Priority = (typeof Priority)[keyof typeof Priority];

/** A unit of work for AudioCacheQueue. */
export interface CacheTask {
  songId: string;
  priority: Priority;
  source: CacheMetaSource;
  triggers?: string[];
}

/** Function that performs the actual download for one CacheTask. */
export type CacheTaskExecutor = (task: CacheTask) => Promise<void>;
