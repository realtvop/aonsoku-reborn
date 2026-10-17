import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  const listenerCallbacks: Array<{
    event: string;
    cb: (event: unknown) => void;
  }> = [];
  let addListenerIndex = 0;

  const mockAddListener = vi.fn(
    (event: string, cb: (event: unknown) => void) => {
      const idx = addListenerIndex++;
      listenerCallbacks.push({ event, cb });
      return Promise.resolve({
        remove: vi.fn(async () => {
          listenerCallbacks.splice(idx, 1);
        }),
      });
    },
  );

  return {
    mockInitialize: vi.fn(async () => ({ ready: true, needsMigration: true })),
    mockSyncAll: vi.fn(async () => {}),
    mockSyncIncremental: vi.fn(async () => {}),
    mockCancelSync: vi.fn(async () => {}),
    mockAddListener,
    mockInvalidateQueries: vi.fn(),
    mockUpdateSyncState: vi.fn(),
    mockAddCacheItem: vi.fn(),
    mockRemoveCacheItem: vi.fn(),
    listenerCallbacks,
  };
});

vi.mock("@/native/data/facade", () => ({
  AonsokuNativeData: {
    initialize: mocks.mockInitialize,
    syncAll: mocks.mockSyncAll,
    syncIncremental: mocks.mockSyncIncremental,
    cancelSync: mocks.mockCancelSync,
    addListener: mocks.mockAddListener,
  },
}));

vi.mock("@/lib/queryClient", () => ({
  queryClient: {
    invalidateQueries: mocks.mockInvalidateQueries,
  },
}));

vi.mock("@/store/cache.store", () => ({
  useCacheStore: {
    getState: () => ({
      actions: {
        updateSyncState: mocks.mockUpdateSyncState,
      },
    }),
  },
}));

vi.mock("@/store/cache-index.store", () => ({
  getCacheIndexItems: () => ({}),
  getCacheIndexActions: () => ({
    addItem: mocks.mockAddCacheItem,
    removeItem: mocks.mockRemoveCacheItem,
  }),
}));

const { nativeSyncAdapter } = await import("./native-sync-adapter");

describe("NativeSyncAdapter", () => {
  beforeEach(() => {
    mocks.mockInitialize.mockClear();
    mocks.mockSyncAll.mockClear();
    mocks.mockSyncIncremental.mockClear();
    mocks.mockCancelSync.mockClear();
    mocks.mockInvalidateQueries.mockClear();
    mocks.mockUpdateSyncState.mockClear();
    mocks.mockAddCacheItem.mockClear();
    mocks.mockRemoveCacheItem.mockClear();
  });

  it("registers native data listeners on construction", () => {
    expect(mocks.mockAddListener).toHaveBeenCalledTimes(3);
  });

  it("registers sync, data, and cover-cache listeners", () => {
    const events = mocks.listenerCallbacks.map((l) => l.event);
    expect(events).toContain("syncStateChanged");
    expect(events).toContain("dataChanged");
    expect(events).toContain("coverCacheChanged");
  });

  it("calls native initialize on first syncAll", async () => {
    const adapterState = nativeSyncAdapter as unknown as {
      initialized: boolean;
    };
    adapterState.initialized = false;
    mocks.mockInitialize.mockClear();

    await nativeSyncAdapter.syncAll();

    expect(mocks.mockInitialize).toHaveBeenCalledTimes(1);
    expect(mocks.mockSyncAll).toHaveBeenCalledTimes(1);
  });

  it("calls native syncIncremental on first call", async () => {
    const adapterState = nativeSyncAdapter as unknown as {
      initialized: boolean;
    };
    adapterState.initialized = false;
    mocks.mockInitialize.mockClear();

    await nativeSyncAdapter.syncIncremental();

    expect(mocks.mockInitialize).toHaveBeenCalledTimes(1);
    expect(mocks.mockSyncIncremental).toHaveBeenCalledTimes(1);
  });

  it("emits sync state changes to cache store on syncStateChanged event", async () => {
    const adapterState = nativeSyncAdapter as unknown as {
      initialized: boolean;
    };
    adapterState.initialized = false;
    await nativeSyncAdapter.initialize();

    const syncCb = mocks.listenerCallbacks.find(
      (l) => l.event === "syncStateChanged",
    );
    expect(syncCb).toBeDefined();

    syncCb!.cb({ phase: "songs", isSyncing: true, progress: 50 });

    expect(mocks.mockUpdateSyncState).toHaveBeenCalledWith({
      phase: "songs",
      isSyncing: true,
      progress: 50,
    });
  });

  it("invalidates react query keys on dataChanged event", async () => {
    const adapterState = nativeSyncAdapter as unknown as {
      initialized: boolean;
    };
    adapterState.initialized = false;
    await nativeSyncAdapter.initialize();

    const dataCb = mocks.listenerCallbacks.find(
      (l) => l.event === "dataChanged",
    );
    expect(dataCb).toBeDefined();

    dataCb!.cb({ tables: ["artists", "albums"] });

    expect(mocks.mockInvalidateQueries).toHaveBeenCalledWith({
      queryKey: ["artists"],
    });
    expect(mocks.mockInvalidateQueries).toHaveBeenCalledWith({
      queryKey: ["albums"],
    });
  });

  it("invalidates songs and favorites keys on songs dataChanged event", async () => {
    const adapterState = nativeSyncAdapter as unknown as {
      initialized: boolean;
    };
    adapterState.initialized = false;
    await nativeSyncAdapter.initialize();

    const dataCb = mocks.listenerCallbacks.find(
      (l) => l.event === "dataChanged",
    );
    dataCb!.cb({ tables: ["songs"] });

    expect(mocks.mockInvalidateQueries).toHaveBeenCalledWith({
      queryKey: ["songs"],
    });
    expect(mocks.mockInvalidateQueries).toHaveBeenCalledWith({
      queryKey: ["favorites", "count"],
    });
    expect(mocks.mockInvalidateQueries).toHaveBeenCalledWith({
      queryKey: ["favorites", "list"],
    });
  });

  it("mirrors native cover publications into the renderer cache index", () => {
    const coverCb = mocks.listenerCallbacks.find(
      (listener) => listener.event === "coverCacheChanged",
    );

    coverCb!.cb({
      coverArtId: "cover-1",
      file: {
        coverArtId: "cover-1",
        uri: "aonsoku-media://cached?id=cover-1&v=revision-2",
        coverSize: "700",
        sizeBytes: 42,
        revision: "revision-2",
      },
    });

    expect(mocks.mockAddCacheItem).toHaveBeenCalledWith(
      "cover:cover-1",
      expect.objectContaining({
        id: "cover-1",
        coverSize: "700",
        sizeBytes: 42,
        revision: "revision-2",
      }),
    );
  });

  it("calls cancelSync on cancel", () => {
    nativeSyncAdapter.cancel();
    expect(mocks.mockCancelSync).toHaveBeenCalled();
  });
});
