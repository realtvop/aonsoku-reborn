import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getNativePreferences: vi.fn(),
  migrateToNativeStorageIfNeeded: vi.fn(),
}));

vi.mock("@/native/preferences/facade", () => ({
  getNativePreferences: mocks.getNativePreferences,
  isNativePreferencesAvailable: () => true,
}));

vi.mock("@/store/native-migration", () => ({
  migrateToNativeStorageIfNeeded: mocks.migrateToNativeStorageIfNeeded,
}));

describe("native storage initialization", () => {
  beforeEach(() => {
    vi.resetModules();
    mocks.getNativePreferences.mockReset();
    mocks.migrateToNativeStorageIfNeeded.mockReset();
    mocks.getNativePreferences.mockReturnValue({});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("hydrates reads queued before the native snapshot is ready", async () => {
    mocks.migrateToNativeStorageIfNeeded.mockResolvedValue({
      theme_store: JSON.stringify({
        state: { theme: "dark" },
        version: 1,
      }),
    });
    const { createNativeStorage, initNativePrefsCache } = await import(
      "@/store/native-storage"
    );
    const storage = createNativeStorage<{ theme: string }>("theme_store");

    const queuedRead = storage.getItem("theme_store");
    await initNativePrefsCache();

    await expect(queuedRead).resolves.toEqual({
      state: { theme: "dark" },
      version: 1,
    });
  });

  it("releases queued reads when the native snapshot fails", async () => {
    const error = new Error("native bridge unavailable");
    mocks.migrateToNativeStorageIfNeeded.mockRejectedValue(error);
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { createNativeStorage, initNativePrefsCache } = await import(
      "@/store/native-storage"
    );
    const storage = createNativeStorage<{ theme: string }>("theme_store");

    const queuedRead = storage.getItem("theme_store");
    await expect(initNativePrefsCache()).resolves.toBeUndefined();
    await expect(queuedRead).resolves.toBeNull();
    expect(consoleError).toHaveBeenCalledWith(
      "[native-storage] failed to initialize preferences",
      error,
    );
  });

  it("shares one native initialization across callers", async () => {
    mocks.migrateToNativeStorageIfNeeded.mockResolvedValue({});
    const { initNativePrefsCache } = await import("@/store/native-storage");

    await Promise.all([initNativePrefsCache(), initNativePrefsCache()]);

    expect(mocks.getNativePreferences).toHaveBeenCalledTimes(1);
    expect(mocks.migrateToNativeStorageIfNeeded).toHaveBeenCalledTimes(1);
  });
});
