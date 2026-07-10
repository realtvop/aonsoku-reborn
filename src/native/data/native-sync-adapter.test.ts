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

const { nativeSyncAdapter } = await import("./native-sync-adapter");

describe("NativeSyncAdapter", () => {
  beforeEach(() => {
    mocks.mockInitialize.mockClear();
    mocks.mockSyncAll.mockClear();
    mocks.mockSyncIncremental.mockClear();
    mocks.mockCancelSync.mockClear();
    mocks.mockInvalidateQueries.mockClear();
    mocks.mockUpdateSyncState.mockClear();
  });

  it("registers both listeners on construction", () => {
    expect(mocks.mockAddListener).toHaveBeenCalledTimes(2);
  });

  it("registers syncStateChanged and dataChanged listeners", () => {
    const events = mocks.listenerCallbacks.map((l) => l.event);
    expect(events).toContain("syncStateChanged");
    expect(events).toContain("dataChanged");
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

  it("calls cancelSync on cancel", () => {
    nativeSyncAdapter.cancel();
    expect(mocks.mockCancelSync).toHaveBeenCalled();
  });
});
