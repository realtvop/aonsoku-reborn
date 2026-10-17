import type {
  NativeCoverCacheChangedEvent,
  NativeSyncOptions,
} from "@aonsoku/capacitor-native/data";
import { queryClient } from "@/lib/queryClient";
import { AonsokuNativeData } from "@/native/data/facade";
import { coverKey } from "@/service/cache/cache-keys";
import { useCacheStore } from "@/store/cache.store";
import {
  getCacheIndexActions,
  getCacheIndexItems,
} from "@/store/cache-index.store";
import type { SyncState } from "@/types/cache";

class NativeSyncAdapter {
  private listenerHandles: Array<{ remove: () => Promise<void> }> = [];
  private initialized = false;
  private listenerReady: Promise<void>;

  constructor() {
    this.listenerReady = this.setupListeners();
  }

  private async setupListeners() {
    const syncHandle = await AonsokuNativeData.addListener(
      "syncStateChanged",
      (state: Partial<SyncState>) => {
        useCacheStore.getState().actions.updateSyncState(state);
      },
    );
    this.listenerHandles.push(syncHandle);

    const dataHandle = await AonsokuNativeData.addListener(
      "dataChanged",
      (event: { tables: string[] }) => {
        const queryKeyMap: Record<string, string[][]> = {
          artists: [["artists"]],
          albums: [["albums"]],
          songs: [["songs"], ["favorites", "count"], ["favorites", "list"]],
          playlists: [["playlists"], ["playlists", "single"]],
          genres: [["genres"]],
          favorites: [
            ["favorites", "count"],
            ["favorites", "list"],
          ],
        };

        for (const table of event.tables) {
          const keys = queryKeyMap[table];
          if (keys) {
            for (const key of keys) {
              queryClient.invalidateQueries({ queryKey: key });
            }
          }
        }
      },
    );
    this.listenerHandles.push(dataHandle);

    const coverHandle = await AonsokuNativeData.addListener(
      "coverCacheChanged",
      (event: NativeCoverCacheChangedEvent) => {
        const key = coverKey(event.coverArtId);
        if (!event.file) {
          getCacheIndexActions().removeItem(key);
          return;
        }

        const previous = getCacheIndexItems()[key];
        const now = Date.now();
        getCacheIndexActions().addItem(key, {
          id: event.coverArtId,
          type: "cover",
          source: previous?.source ?? "explicit",
          coverSize: event.file.coverSize ?? previous?.coverSize,
          revision: event.file.revision,
          sizeBytes: event.file.sizeBytes ?? previous?.sizeBytes ?? 0,
          cachedAt: Math.max(now, (previous?.cachedAt ?? 0) + 1),
          lastAccessedAt: now,
        });
      },
    );
    this.listenerHandles.push(coverHandle);
  }

  async initialize(): Promise<void> {
    if (this.initialized) return;
    await this.listenerReady;
    await AonsokuNativeData.initialize();
    this.initialized = true;
  }

  async syncAll(options?: Record<string, unknown>): Promise<void> {
    await this.initialize();
    await AonsokuNativeData.syncAll(options);
  }

  async syncIncremental(options?: Record<string, unknown>): Promise<void> {
    await this.initialize();
    await AonsokuNativeData.syncIncremental(
      options as NativeSyncOptions | undefined,
    );
  }

  cancel(): void {
    AonsokuNativeData.cancelSync();
  }
}

export const nativeSyncAdapter = new NativeSyncAdapter();
