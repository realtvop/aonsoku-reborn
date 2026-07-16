import { expose, type Remote, transfer, wrap } from "comlink";
import { queryClient } from "@/lib/queryClient";
import { isNativeDataAvailable } from "@/native/data/facade";
import { metadataSyncService } from "@/service/cache/metadata-sync";
import { useAppStore } from "@/store/app.store";
import { useCacheStore } from "@/store/cache.store";
import { getCacheIndexActions } from "@/store/cache-index.store";
import { usePlayerStore } from "@/store/player.store";
import type { SyncState } from "@/types/cache";
import type { AuthType } from "@/types/serverConfig";

interface WorkerAuthConfig {
  url: string;
  username: string;
  password: string;
  authType: AuthType | null;
  protocolVersion?: string;
  serverType?: string | null;
}

interface SyncOptions {
  includeCoverArt?: boolean;
  includeFullSongs?: boolean;
  mode?: "full" | "incremental";
  songCount?: number;
  useAlbumCoverForSongs?: boolean;
  coverArtConcurrency?: number;
}

interface Callbacks {
  onSyncStateUpdate(state: Partial<SyncState>): void;
  onInvalidateQueries(keys: string[][]): void;
  onLastSyncedAt(timestamp: number): void;
  onCacheIndexRefresh(): void;
}

interface SyncWorkerService {
  syncAll(options: SyncOptions): Promise<void>;
  syncIncremental(options: SyncOptions): Promise<void>;
  cancel(): void;
  initAuth(config: WorkerAuthConfig): void;
  updateAuth(config: WorkerAuthConfig): void;
  setCallbackPort(port: MessagePort): void;
}

async function refreshCacheIndexFromIDB(): Promise<void> {
  try {
    const { libraryDb } = await import("@/store/library-db");
    const rows = await libraryDb.cacheMeta.toArray();
    const actions = getCacheIndexActions();
    for (const row of rows) {
      actions.addItem(row.key, {
        id: row.id,
        type: row.type,
        source: row.source,
        triggers: row.triggers,
        coverSize: row.type === "cover" ? row.coverSize : undefined,
        sizeBytes: row.sizeBytes,
        cachedAt: row.cachedAt,
        lastAccessedAt: row.lastAccessedAt,
        removedFromServer: row.removedFromServer,
      });
    }
  } catch (err) {
    console.warn("[syncWorkerAdapter] failed to refresh cache index:", err);
  }
}

class SyncWorkerAdapter {
  private worker: Worker;
  private proxy: Remote<SyncWorkerService>;
  private unsubAuth: (() => void) | null = null;
  private authReady: Promise<void>;
  private lastServerUrl: string;
  private callbackPort: MessagePort | null = null;

  constructor() {
    this.worker = new Worker(new URL("./sync.worker.ts", import.meta.url), {
      type: "module",
    });
    this.worker.onerror = (event) => {
      console.error("[syncWorkerAdapter] Worker error:", event.message);
      useCacheStore.getState().actions.updateSyncState({
        phase: "error",
        isSyncing: false,
      });
    };
    this.proxy = wrap<SyncWorkerService>(this.worker);

    const initialConfig = this.buildAuthConfig();
    this.lastServerUrl = initialConfig.url;
    this.setupCallbacks();
    this.authReady = this.proxy.initAuth(initialConfig);
    this.unsubAuth = useAppStore.subscribe((state) => {
      const config = this.buildAuthConfig(state.data);
      if (config.url !== this.lastServerUrl) {
        this.lastServerUrl = config.url;
        this.proxy.cancel();
      }
      this.proxy.updateAuth(config);
    });
  }

  private buildAuthConfig(
    data?: Parameters<typeof useAppStore.getState>[0]["data"],
  ): WorkerAuthConfig {
    const d = data ?? useAppStore.getState().data;
    return {
      url: d.url,
      username: d.username,
      password: d.password,
      authType: d.authType,
      protocolVersion: d.protocolVersion,
      serverType: d.serverType,
    };
  }

  private setupCallbacks(): void {
    const { port1, port2 } = new MessageChannel();
    this.callbackPort = port1;

    const callbacks: Callbacks = {
      onSyncStateUpdate(state: Partial<SyncState>) {
        useCacheStore.getState().actions.updateSyncState(state);
      },
      onInvalidateQueries(keys: string[][]) {
        for (const key of keys) {
          queryClient.invalidateQueries({ queryKey: key });
        }
      },
      onLastSyncedAt(timestamp: number) {
        useCacheStore.getState().actions.setLastSyncedAt(timestamp);
      },
      onCacheIndexRefresh() {
        refreshCacheIndexFromIDB();
      },
    };

    expose(callbacks, port1);
    this.proxy.setCallbackPort(transfer(port2, [port2]));
  }

  private buildSyncOptions(options?: {
    includeCoverArt?: boolean;
    includeFullSongs?: boolean;
  }): SyncOptions {
    const state = useCacheStore.getState();
    const appState = useAppStore.getState();
    const playerState = usePlayerStore.getState();
    return {
      includeCoverArt: options?.includeCoverArt ?? state.settings.syncCoverArt,
      includeFullSongs:
        options?.includeFullSongs ?? state.settings.libraryCaching,
      songCount: appState.data.songCount ?? 100_000,
      useAlbumCoverForSongs:
        playerState.settings.coverArt.useAlbumCoverForSongs,
      coverArtConcurrency: state.settings.coverArtConcurrency,
    };
  }

  async syncAll(options?: {
    includeCoverArt?: boolean;
    includeFullSongs?: boolean;
  }): Promise<void> {
    await this.authReady;
    await this.proxy.syncAll(this.buildSyncOptions(options));
  }

  async syncIncremental(options?: {
    includeCoverArt?: boolean;
    includeFullSongs?: boolean;
  }): Promise<void> {
    await this.authReady;
    await this.proxy.syncIncremental(this.buildSyncOptions(options));
  }

  cancel(): void {
    this.proxy.cancel();
  }

  terminate(): void {
    this.unsubAuth?.();
    this.callbackPort?.close();
    this.worker.terminate();
  }
}

/**
 * Lazy proxy for the native sync adapter (Capacitor iOS/Android).
 *
 * Never falls back to IndexedDB on native platforms. Waits for the
 * native adapter module to load before delegating calls.
 */
class LazyNativeSyncAdapter {
  private adapter: {
    syncAll(options?: Record<string, unknown>): Promise<void>;
    syncIncremental(options?: Record<string, unknown>): Promise<void>;
    cancel(): void;
  } | null = null;
  private readyPromise: Promise<void>;

  constructor() {
    this.readyPromise = this.load();
  }

  private async load() {
    try {
      const { nativeSyncAdapter } = await import(
        "@/native/data/native-sync-adapter"
      );
      this.adapter = nativeSyncAdapter;
    } catch (err) {
      console.warn("[syncWorkerAdapter] native adapter unavailable:", err);
    }
  }

  private async ensure() {
    await this.readyPromise;
    return this.adapter;
  }

  async syncAll(options?: {
    includeCoverArt?: boolean;
    includeFullSongs?: boolean;
  }): Promise<void> {
    const a = await this.ensure();
    if (a) await a.syncAll(options as Record<string, unknown>);
  }

  async syncIncremental(options?: {
    includeCoverArt?: boolean;
    includeFullSongs?: boolean;
  }): Promise<void> {
    const a = await this.ensure();
    if (a) await a.syncIncremental(options as Record<string, unknown>);
  }

  cancel(): void {
    if (this.adapter) {
      this.adapter.cancel();
    }
  }
}

function createSyncService():
  | SyncWorkerAdapter
  | typeof metadataSyncService
  | LazyNativeSyncAdapter {
  if (isNativeDataAvailable()) {
    return new LazyNativeSyncAdapter();
  }

  try {
    if (typeof Worker === "undefined") {
      return metadataSyncService;
    }
    return new SyncWorkerAdapter();
  } catch (err) {
    console.warn(
      "[syncWorkerAdapter] failed to create Worker, falling back to main thread:",
      err,
    );
    return metadataSyncService;
  }
}

const syncService = createSyncService();

export { syncService };
