import { Capacitor } from "@capacitor/core";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  getNativePreferencesAvailability,
  isNativePreferencesAvailable,
} from "./facade";

const mocks = vi.hoisted(() => ({
  plugin: {},
  mockIsNativePlatform: vi.fn(),
  mockGetPlatform: vi.fn(),
  mockIsPluginAvailable: vi.fn(),
}));

vi.mock("@capacitor/core", () => ({
  Capacitor: {
    isNativePlatform: mocks.mockIsNativePlatform,
    getPlatform: mocks.mockGetPlatform,
    isPluginAvailable: mocks.mockIsPluginAvailable,
  },
}));

vi.mock("@aonsoku/capacitor-native/preferences", () => ({
  AonsokuNativePreferences: mocks.plugin,
  NATIVE_PREFERENCES_PLUGIN_NAME: "AonsokuNativePreferences",
}));

const mockIsNativePlatform = vi.mocked(Capacitor.isNativePlatform);
const mockGetPlatform = vi.mocked(Capacitor.getPlatform);
const mockIsPluginAvailable = vi.mocked(Capacitor.isPluginAvailable);

describe("native preferences facade", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    mockIsNativePlatform.mockReset();
    mockGetPlatform.mockReset();
    mockIsPluginAvailable.mockReset();
    mockIsNativePlatform.mockReturnValue(false);
    mockGetPlatform.mockReturnValue("web");
    mockIsPluginAvailable.mockReturnValue(false);
  });

  it("uses the Electron main-process preferences bridge when exposed", () => {
    const desktopPlugin = { getAllPreferences: vi.fn() };
    vi.stubGlobal("window", { aonsokuNativePreferences: desktopPlugin });

    expect(getNativePreferencesAvailability()).toEqual({
      available: true,
      plugin: desktopPlugin,
    });
    expect(isNativePreferencesAvailable()).toBe(true);
  });

  it("requires a native platform", () => {
    expect(isNativePreferencesAvailable()).toBe(false);
    expect(mockIsPluginAvailable).not.toHaveBeenCalled();
  });

  it.each(["ios", "android"])(
    "is available on supported %s platforms",
    (platform) => {
      mockIsNativePlatform.mockReturnValue(true);
      mockGetPlatform.mockReturnValue(platform);
      mockIsPluginAvailable.mockReturnValue(true);

      expect(getNativePreferencesAvailability()).toEqual({
        available: true,
        plugin: mocks.plugin,
      });
      expect(isNativePreferencesAvailable()).toBe(true);
      expect(mockIsPluginAvailable).toHaveBeenCalledWith(
        "AonsokuNativePreferences",
      );
    },
  );

  it("keeps unsupported native platforms unavailable", () => {
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("electron");
    mockIsPluginAvailable.mockReturnValue(true);

    expect(isNativePreferencesAvailable()).toBe(false);
  });
});
