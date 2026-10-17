import { get } from "idb-keyval";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import { immer } from "zustand/middleware/immer";
import { shallow } from "zustand/shallow";
import { createWithEqualityFn } from "zustand/traditional";
import {
  albumKey,
  audioKey,
  avatarKey,
  coverKey,
  playlistKey,
} from "@/service/cache/cache-keys";
import { cacheIndexStore, idbSetWithRetry } from "@/store/idb";
import type { CacheMetaRow } from "@/store/library-db";
import { CachedItemMeta, CacheMetaSource } from "@/types/cache";

const IDB_KEY = "cache-index-v1";

interface CacheIndexState {
  items: Record<string, CachedItemMeta>;
  loaded: boolean;
  /** Per-song download progress: songId → 0–100 for percentage, or negative byte count. Not persisted. */
  downloads: Record<string, number>;
  actions: {
    loadFromIDB: () => Promise<void>;
    addItem: (key: string, meta: CachedItemMeta) => void;
    removeItem: (key: string) => void;
    touchItem: (key: string) => void;
    setRemovedFromServer: (key: string, removed: boolean) => void;
    clear: () => void;
    setDownloadProgress: (songId: string, progress: number) => void;
    clearDownloadProgress: (songId: string) => void;
  };
}

let persistTimer: ReturnType<typeof setTimeout> | null = null;
let indexFlushed = false;

const pendingTouches = new Map<string, number>();
let touchFlushTimer: ReturnType<typeof setTimeout> | null = null;

function flushPendingTouches(): void {
  if (pendingTouches.size === 0) return;
  const entries = Array.from(pendingTouches.entries());
  pendingTouches.clear();
  touchFlushTimer = null;
  import("@/store/library-db")
    .then(({ libraryDb }) => {
      for (const [key, lastAccessedAt] of entries) {
        libraryDb.cacheMeta
          .update(key, { lastAccessedAt })
          .catch((err: unknown) => {
            console.warn(`[cacheIndex] failed to touch cacheMeta ${key}:`, err);
          });
      }
    })
    .catch(() => {});
}

function scheduleTouchFlush(key: string, lastAccessedAt: number): void {
  pendingTouches.set(key, lastAccessedAt);
  if (!touchFlushTimer) {
    touchFlushTimer = setTimeout(flushPendingTouches, 2000);
  }
}

function schedulePersist(items: Record<string, CachedItemMeta>) {
  if (persistTimer) clearTimeout(persistTimer);
  indexFlushed = false;
  persistTimer = setTimeout(() => {
    persistTimer = null;
    indexFlushed = true;
    idbSetWithRetry(IDB_KEY, items, cacheIndexStore);
  }, 500);
}

function migrateStoredItems(
  stored: Record<string, Partial<CachedItemMeta> | undefined> | undefined,
): Record<string, CachedItemMeta> {
  if (!stored) return {};

  // Pre-P2.1 entries lack the `source` field. Default them to
  // "explicit" so they are treated as protected downloads, never
  // silently evicted by LRU.
  const migrated: Record<string, CachedItemMeta> = {};
  for (const [key, meta] of Object.entries(stored)) {
    if (!meta) continue;
    migrated[key] = {
      ...(meta as CachedItemMeta),
      source: meta.source ?? "explicit",
    };
  }
  return migrated;
}

function cacheMetaRowsToItems(
  rows: CacheMetaRow[],
): Record<string, CachedItemMeta> {
  const items: Record<string, CachedItemMeta> = {};
  for (const { key, ...meta } of rows) {
    items[key] = {
      ...meta,
      source: meta.source ?? "explicit",
    };
  }
  return items;
}

function flushIndexPersist() {
  if (indexFlushed) return;
  if (persistTimer) {
    clearTimeout(persistTimer);
    persistTimer = null;
  }
  if (touchFlushTimer) {
    clearTimeout(touchFlushTimer);
    touchFlushTimer = null;
  }
  flushPendingTouches();
  indexFlushed = true;
  const items = useCacheIndexStore.getState().items;
  idbSetWithRetry(IDB_KEY, items, cacheIndexStore);
}

function registerFlushListeners() {
  if (typeof document === "undefined" || typeof window === "undefined") return;
  const handleVisibilityChange = () => {
    if (document.hidden) flushIndexPersist();
  };
  const handleBeforeUnload = () => {
    flushIndexPersist();
  };
  document.addEventListener("visibilitychange", handleVisibilityChange);
  window.addEventListener("beforeunload", handleBeforeUnload);
}
registerFlushListeners();

export const useCacheIndexStore = createWithEqualityFn<CacheIndexState>()(
  subscribeWithSelector(
    devtools(
      immer((setState, getState) => ({
        items: {},
        loaded: false,
        downloads: {},
        actions: {
          loadFromIDB: async () => {
            try {
              const [storedResult, cacheMetaRowsResult] =
                await Promise.allSettled([
                  get<Record<string, Partial<CachedItemMeta> | undefined>>(
                    IDB_KEY,
                    cacheIndexStore,
                  ),
                  import("@/store/library-db").then(({ libraryDb }) =>
                    libraryDb.cacheMeta.toArray(),
                  ),
                ]);
              if (storedResult.status === "rejected") {
                console.warn(
                  "Failed to load legacy cache index",
                  storedResult.reason,
                );
              }
              if (cacheMetaRowsResult.status === "rejected") {
                console.warn(
                  "Failed to load cache metadata from Dexie",
                  cacheMetaRowsResult.reason,
                );
              }
              const stored =
                storedResult.status === "fulfilled"
                  ? storedResult.value
                  : undefined;
              const cacheMetaRows =
                cacheMetaRowsResult.status === "fulfilled"
                  ? cacheMetaRowsResult.value
                  : [];
              const migrated = migrateStoredItems(stored);
              const fromCacheMeta = cacheMetaRowsToItems(cacheMetaRows);
              setState((state) => {
                state.items = {
                  ...migrated,
                  ...fromCacheMeta,
                  ...state.items,
                };
                state.loaded = true;
              });
            } catch (err) {
              console.error("Failed to load cache index from IDB", err);
              setState((state) => {
                state.loaded = true;
              });
            }
          },
          addItem: (key, meta) => {
            setState((state) => {
              state.items[key] = meta;
            });
            schedulePersist(getState().items);
          },
          removeItem: (key) => {
            setState((state) => {
              delete state.items[key];
            });
            schedulePersist(getState().items);
          },
          touchItem: (key) => {
            const now = Date.now();
            setState((state) => {
              const item = state.items[key];
              if (item) {
                item.lastAccessedAt = now;
              }
            });
            schedulePersist(getState().items);
            scheduleTouchFlush(key, now);
          },
          setRemovedFromServer: (key, removed) => {
            setState((state) => {
              const item = state.items[key];
              if (!item) return;
              if (removed) {
                item.removedFromServer = true;
              } else {
                delete item.removedFromServer;
              }
            });
            schedulePersist(getState().items);
          },
          clear: () => {
            setState((state) => {
              state.items = {};
            });
            schedulePersist({});
          },
          setDownloadProgress: (songId, progress) => {
            setState((state) => {
              state.downloads[songId] = progress;
            });
          },
          clearDownloadProgress: (songId) => {
            setState((state) => {
              delete state.downloads[songId];
            });
          },
        },
      })),
      { name: "cache_index_store" },
    ),
  ),
  shallow,
);

export function isAudioCached(songId: string): boolean {
  return audioKey(songId) in useCacheIndexStore.getState().items;
}

export function isCoverCached(coverArtId: string): boolean {
  return coverKey(coverArtId) in useCacheIndexStore.getState().items;
}

export function isAvatarCached(username: string): boolean {
  return avatarKey(username) in useCacheIndexStore.getState().items;
}

export function isAlbumCached(albumId: string): boolean {
  return albumKey(albumId) in useCacheIndexStore.getState().items;
}

export function isPlaylistCached(playlistId: string): boolean {
  return playlistKey(playlistId) in useCacheIndexStore.getState().items;
}

export function getCacheIndexItems(): Record<string, CachedItemMeta> {
  return useCacheIndexStore.getState().items;
}

export function getCacheIndexActions() {
  return useCacheIndexStore.getState().actions;
}

export const useIsAudioCached = (songId: string) =>
  useCacheIndexStore((state) => audioKey(songId) in state.items);

export const useIsAlbumCached = (albumId: string) =>
  useCacheIndexStore((state) => albumKey(albumId) in state.items);

export const useIsPlaylistCached = (playlistId: string) =>
  useCacheIndexStore((state) => playlistKey(playlistId) in state.items);

export const useIsCoverCached = (coverArtId: string) =>
  useCacheIndexStore((state) => coverKey(coverArtId) in state.items);

function coverCacheVersion(meta: CachedItemMeta | undefined): string {
  if (!meta) return "missing";
  if (meta.revision) return `revision:${meta.revision}`;
  return ["legacy", meta.coverSize ?? "", meta.sizeBytes, meta.cachedAt].join(
    ":",
  );
}

/**
 * Subscribe only to content metadata for the requested covers. Access-time
 * touches intentionally do not change this value, so reading a cached URL
 * cannot trigger a lookup loop.
 */
export const useCoverCacheVersion = (coverArtIds: string[]) =>
  useCacheIndexStore((state) =>
    coverArtIds
      .map((coverArtId) => coverCacheVersion(state.items[coverKey(coverArtId)]))
      .join("|"),
  );

export const useIsAvatarCached = (username: string) =>
  useCacheIndexStore((state) => avatarKey(username) in state.items);

export const useCacheIndexLoaded = () =>
  useCacheIndexStore((state) => state.loaded);

export const useCacheIndexActions = () =>
  useCacheIndexStore((state) => state.actions);

export interface CachePoolBreakdown {
  sizeBytes: number;
  count: number;
}

export interface CachePoolStats {
  /** Audio tagged `source: "explicit"`. */
  explicit: CachePoolBreakdown;
  /** Audio tagged `source: "smart"`. */
  smart: CachePoolBreakdown;
  /** Audio tagged `source: "lru"`. */
  lru: CachePoolBreakdown;
  /** Every `type: "cover"` entry regardless of source. */
  assets: CachePoolBreakdown;
}

function emptyBreakdown(): CachePoolBreakdown {
  return { sizeBytes: 0, count: 0 };
}

export function computePoolStats(
  items: Record<string, CachedItemMeta>,
): CachePoolStats {
  const stats: CachePoolStats = {
    explicit: emptyBreakdown(),
    smart: emptyBreakdown(),
    lru: emptyBreakdown(),
    assets: emptyBreakdown(),
  };
  for (const meta of Object.values(items)) {
    if (meta.type === "cover") {
      stats.assets.sizeBytes += meta.sizeBytes;
      stats.assets.count += 1;
      continue;
    }
    const bucket = poolForAudioSource(meta.source);
    stats[bucket].sizeBytes += meta.sizeBytes;
    stats[bucket].count += 1;
  }
  return stats;
}

function poolForAudioSource(source: CacheMetaSource): keyof CachePoolStats {
  switch (source) {
    case "explicit":
      return "explicit";
    case "smart":
      return "smart";
    case "lru":
      return "lru";
  }
}

/** Count of cached songs no longer present in the synced library. */
export function useOrphanCount(): number {
  return useCacheIndexStore((state) => {
    let n = 0;
    for (const meta of Object.values(state.items)) {
      if (meta.type === "audio" && meta.removedFromServer) n += 1;
    }
    return n;
  });
}

/**
 * Aggregated cache stats grouped by pool for the storage settings UI.
 * Computed on every change to the cache index — cheap because the
 * index tracks O(hundreds) of entries even with a large library.
 */
export const useCachePoolStats = (): CachePoolStats =>
  useCacheIndexStore((state) => computePoolStats(state.items), shallow);

export const useDownloadProgress = (songId: string): number | undefined =>
  useCacheIndexStore((state) => state.downloads[songId]);

export const useDownloadBytes = (songId: string): number | undefined =>
  useCacheIndexStore((state) => {
    const value = state.downloads[songId];
    return value !== undefined && value < 0 ? -value : undefined;
  });

export interface ActiveDownload {
  songId: string;
  progress: number;
  isCompleted: boolean;
  isIndeterminate: boolean;
  bytesReceived: number;
}

function activeDownloadsEqual(
  a: ReturnType<typeof useActiveDownloadsSummary>,
  b: ReturnType<typeof useActiveDownloadsSummary>,
): boolean {
  if (
    a.count !== b.count ||
    a.averageProgress !== b.averageProgress ||
    a.hasDownloads !== b.hasDownloads ||
    a.downloads.length !== b.downloads.length
  ) {
    return false;
  }
  for (let i = 0; i < a.downloads.length; i++) {
    const ad = a.downloads[i];
    const bd = b.downloads[i];
    if (
      ad.songId !== bd.songId ||
      ad.progress !== bd.progress ||
      ad.isCompleted !== bd.isCompleted ||
      ad.isIndeterminate !== bd.isIndeterminate ||
      ad.bytesReceived !== bd.bytesReceived
    ) {
      return false;
    }
  }
  return true;
}

export const useActiveDownloadsSummary = () =>
  useCacheIndexStore((state) => {
    const downloads: ActiveDownload[] = [];
    let totalProgress = 0;
    let determinateCount = 0;

    for (const [songId, value] of Object.entries(state.downloads)) {
      const isIndeterminate = value < 0;
      const isCompleted = !isIndeterminate && value === 100;
      const progress = isIndeterminate ? 0 : value;
      const bytesReceived = isIndeterminate ? -value : 0;

      downloads.push({
        songId,
        progress,
        isCompleted,
        isIndeterminate,
        bytesReceived,
      });

      if (!isIndeterminate) {
        totalProgress += value;
        determinateCount++;
      }
    }

    const averageProgress =
      determinateCount > 0 ? Math.round(totalProgress / determinateCount) : 0;

    return {
      downloads,
      count: downloads.length,
      averageProgress,
      hasDownloads: downloads.length > 0,
    };
  }, activeDownloadsEqual);
