import { beforeEach, describe, expect, it, vi } from "vitest";
import { getNativeDataAvailability, isNativeDataAvailable } from "./facade";

const mocks = vi.hoisted(() => ({
  isNativePlatform: vi.fn(() => false),
  getPlatform: vi.fn(() => "web"),
  isPluginAvailable: vi.fn(() => false),
  capacitorPlugin: {},
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
  beforeEach(() => vi.unstubAllGlobals());

  it("uses the Electron main-process data bridge", () => {
    const plugin = { getSongs: vi.fn() };
    vi.stubGlobal("window", { aonsokuNativeData: plugin });

    expect(getNativeDataAvailability()).toEqual({ available: true, plugin });
    expect(isNativeDataAvailable()).toBe(true);
  });

  it("keeps web unavailable", () => {
    expect(getNativeDataAvailability()).toMatchObject({ available: false });
  });
});
