import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  AonsokuNativeData,
  getNativeDataAvailability,
  isNativeDataAvailable,
} from "./facade";

const mocks = vi.hoisted(() => ({
  isNativePlatform: vi.fn(() => false),
  getPlatform: vi.fn(() => "web"),
  isPluginAvailable: vi.fn(() => false),
  clearCoverImages: vi.fn(async () => ({ deletedCount: 1 })),
  capacitorPlugin: {
    clearCoverImages: () => mocks.clearCoverImages(),
  },
}));

vi.mock("@capacitor/core", () => ({
  Capacitor: {
    isNativePlatform: mocks.isNativePlatform,
    getPlatform: mocks.getPlatform,
    isPluginAvailable: mocks.isPluginAvailable,
  },
}));

vi.mock("@aonsoku/capacitor-native/data", () => ({
  AonsokuNativeData: mocks.capacitorPlugin,
  NATIVE_DATA_PLUGIN_NAME: "AonsokuNativeData",
}));

describe("native data facade", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    mocks.isNativePlatform.mockReturnValue(false);
    mocks.getPlatform.mockReturnValue("web");
    mocks.isPluginAvailable.mockReturnValue(false);
    mocks.clearCoverImages.mockClear();
  });

  it("uses the Electron main-process data bridge", () => {
    const plugin = { getSongs: vi.fn() };
    vi.stubGlobal("window", { aonsokuNativeData: plugin });

    expect(getNativeDataAvailability()).toEqual({ available: true, plugin });
    expect(isNativeDataAvailable()).toBe(true);
  });

  it("keeps web unavailable", () => {
    expect(getNativeDataAvailability()).toMatchObject({ available: false });
  });

  it("forwards iOS calls to the registered Capacitor plugin", async () => {
    mocks.isNativePlatform.mockReturnValue(true);
    mocks.getPlatform.mockReturnValue("ios");
    mocks.isPluginAvailable.mockReturnValue(true);

    expect(getNativeDataAvailability()).toEqual({
      available: true,
      plugin: mocks.capacitorPlugin,
    });
    await expect(AonsokuNativeData.clearCoverImages()).resolves.toEqual({
      deletedCount: 1,
    });
    expect(mocks.clearCoverImages).toHaveBeenCalledTimes(1);
  });
});
