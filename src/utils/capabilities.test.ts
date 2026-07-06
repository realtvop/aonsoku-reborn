import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@capacitor/core", () => ({
  Capacitor: {
    getPlatform: vi.fn(),
    isNativePlatform: vi.fn(),
  },
}));

vi.mock("@/utils/desktop", () => ({
  isDesktop: vi.fn(),
  hasElectronBridge: vi.fn(),
  hasLanControlBridge: vi.fn(),
}));

vi.mock("@/utils/platform", () => ({
  isIOS: vi.fn(),
  isIPad: vi.fn(),
  isSafari: vi.fn(),
  isAndroid: vi.fn(),
}));

import { Capacitor } from "@capacitor/core";
import { hasElectronBridge, isDesktop } from "@/utils/desktop";
import { isAndroid, isIOS } from "@/utils/platform";
import {
  detectRuntime,
  getDesktopCapabilities,
  getPlaybackCapabilities,
  getRuntime,
  resetRuntimeCache,
} from "@/utils/capabilities";

const mockIsDesktop = vi.mocked(isDesktop);
const mockHasElectronBridge = vi.mocked(hasElectronBridge);
const mockIsIOS = vi.mocked(isIOS);
const mockIsAndroid = vi.mocked(isAndroid);
const mockIsNativePlatform = vi.mocked(Capacitor.isNativePlatform);
const mockGetPlatform = vi.mocked(Capacitor.getPlatform);

beforeEach(() => {
  resetRuntimeCache();
  mockIsDesktop.mockReturnValue(false);
  mockHasElectronBridge.mockReturnValue(false);
  mockIsIOS.mockReturnValue(false);
  mockIsAndroid.mockReturnValue(false);
  mockIsNativePlatform.mockReturnValue(false);
  mockGetPlatform.mockReturnValue("web");
});

describe("detectRuntime", () => {
  beforeEach(() => {
    resetRuntimeCache();
  });

  it("returns 'electron' when isDesktop() is true", () => {
    mockIsDesktop.mockReturnValue(true);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(false);
    expect(detectRuntime()).toBe("electron");
  });

  it("returns 'web' for iOS browsers outside Capacitor", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(true);
    mockIsAndroid.mockReturnValue(false);
    mockIsNativePlatform.mockReturnValue(false);
    expect(detectRuntime()).toBe("web");
  });

  it("returns 'web' for Android browsers outside Capacitor", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(true);
    mockIsNativePlatform.mockReturnValue(false);
    expect(detectRuntime()).toBe("web");
  });

  it("returns 'capacitor-ios' when Capacitor reports native iOS", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(true);
    mockIsAndroid.mockReturnValue(false);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    expect(detectRuntime()).toBe("capacitor-ios");
  });

  it("returns 'capacitor-android' when Capacitor reports native Android", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(true);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("android");
    expect(detectRuntime()).toBe("capacitor-android");
  });

  it("returns 'web' when none of the platform checks are true", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(false);
    expect(detectRuntime()).toBe("web");
  });

  it("prioritizes electron over ios when both are true", () => {
    mockIsDesktop.mockReturnValue(true);
    mockIsIOS.mockReturnValue(true);
    mockIsAndroid.mockReturnValue(false);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    expect(detectRuntime()).toBe("electron");
  });

  it("prioritizes electron over android when both are true", () => {
    mockIsDesktop.mockReturnValue(true);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(true);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("android");
    expect(detectRuntime()).toBe("electron");
  });
});

describe("getRuntime caching", () => {
  beforeEach(() => {
    resetRuntimeCache();
  });

  it("caches the runtime on first call", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(false);
    expect(getRuntime()).toBe("web");

    mockIsIOS.mockReturnValue(true);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    expect(getRuntime()).toBe("web");
  });

  it("re-evaluates after resetRuntimeCache", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(false);
    expect(getRuntime()).toBe("web");

    resetRuntimeCache();
    mockIsIOS.mockReturnValue(true);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    expect(getRuntime()).toBe("capacitor-ios");
  });
});

describe("getPlaybackCapabilities", () => {
  beforeEach(() => {
    resetRuntimeCache();
  });

  it("returns web capabilities by default", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(false);

    const caps = getPlaybackCapabilities();
    expect(caps.canSetVolume).toBe(true);
    expect(caps.requiresSystemVolume).toBe(false);
    expect(caps.supportsWebAudioReplayGain).toBe(true);
    expect(caps.supportsNativePlayback).toBe(false);
    expect(caps.supportsBackgroundPlayback).toBe(false);
  });

  it("preserves iOS system-volume behavior for iOS web", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(true);
    mockIsAndroid.mockReturnValue(false);
    mockIsNativePlatform.mockReturnValue(false);

    const caps = getPlaybackCapabilities();
    expect(caps.canSetVolume).toBe(false);
    expect(caps.requiresSystemVolume).toBe(true);
    expect(caps.supportsWebAudioReplayGain).toBe(true);
    expect(caps.supportsNativePlayback).toBe(false);
    expect(caps.supportsBackgroundPlayback).toBe(false);
  });

  it("returns electron capabilities", () => {
    mockIsDesktop.mockReturnValue(true);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(false);

    const caps = getPlaybackCapabilities();
    expect(caps.canSetVolume).toBe(true);
    expect(caps.requiresSystemVolume).toBe(false);
    expect(caps.supportsWebAudioReplayGain).toBe(false);
    expect(caps.supportsNativePlayback).toBe(true);
    expect(caps.supportsBackgroundPlayback).toBe(true);
  });

  it("returns capacitor-ios capabilities", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(true);
    mockIsAndroid.mockReturnValue(false);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");

    const caps = getPlaybackCapabilities();
    expect(caps.canSetVolume).toBe(false);
    expect(caps.requiresSystemVolume).toBe(true);
    expect(caps.supportsWebAudioReplayGain).toBe(false);
    expect(caps.supportsNativePlayback).toBe(true);
    expect(caps.supportsBackgroundPlayback).toBe(true);
  });

  it("returns capacitor-android capabilities", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(true);
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("android");

    const caps = getPlaybackCapabilities();
    expect(caps.canSetVolume).toBe(true);
    expect(caps.requiresSystemVolume).toBe(true);
    expect(caps.supportsSystemVolumeControl).toBe(true);
    expect(caps.supportsWebAudioReplayGain).toBe(false);
    expect(caps.supportsNativePlayback).toBe(true);
    expect(caps.supportsBackgroundPlayback).toBe(true);
  });

  it("capabilities object matches PlaybackCapabilities interface shape", () => {
    mockIsDesktop.mockReturnValue(false);
    mockIsIOS.mockReturnValue(false);
    mockIsAndroid.mockReturnValue(false);

    const caps = getPlaybackCapabilities();
    const keys = Object.keys(caps).sort();
    expect(keys).toEqual(
      [
        "canSetVolume",
        "requiresSystemVolume",
        "supportsSystemVolumeControl",
        "supportsWebAudioReplayGain",
        "supportsNativePlayback",
        "supportsBackgroundPlayback",
      ].sort(),
    );
  });
});

describe("getDesktopCapabilities", () => {
  beforeEach(() => {
    mockHasElectronBridge.mockReturnValue(false);
    mockIsDesktop.mockReturnValue(false);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns no desktop integration when bridge is absent", () => {
    mockHasElectronBridge.mockReturnValue(false);
    mockIsDesktop.mockReturnValue(false);

    const caps = getDesktopCapabilities();
    expect(caps.hasDesktopIntegration).toBe(false);
    expect(caps.hasLanControl).toBe(false);
    expect(caps.hasNativeThemeSync).toBe(false);
    expect(caps.hasUpdateCheck).toBe(false);
  });

  it("returns desktop integration when bridge is present", () => {
    mockHasElectronBridge.mockReturnValue(true);
    mockIsDesktop.mockReturnValue(true);

    const caps = getDesktopCapabilities();
    expect(caps.hasDesktopIntegration).toBe(true);
    expect(caps.hasNativeThemeSync).toBe(true);
    expect(caps.hasUpdateCheck).toBe(true);
  });

  it("detects LAN control when the Electron bridge exposes it", () => {
    mockHasElectronBridge.mockReturnValue(true);
    mockIsDesktop.mockReturnValue(true);
    vi.stubGlobal("window", {
      api: {
        lanControl: {},
      },
    });

    const caps = getDesktopCapabilities();
    expect(caps.hasLanControl).toBe(true);
  });
});

describe("consistency with isIOS for volume control", () => {
  beforeEach(() => {
    resetRuntimeCache();
  });

  it("canSetVolume is false exactly when isIOS is true on non-desktop", () => {
    mockIsDesktop.mockReturnValue(false);

    mockIsIOS.mockReturnValue(true);
    mockIsAndroid.mockReturnValue(false);
    expect(getPlaybackCapabilities().canSetVolume).toBe(false);

    resetRuntimeCache();
    mockIsIOS.mockReturnValue(false);
    expect(getPlaybackCapabilities().canSetVolume).toBe(true);
  });

  it("canSetVolume is true on desktop even if isIOS is true", () => {
    mockIsDesktop.mockReturnValue(true);
    mockIsIOS.mockReturnValue(true);
    mockIsAndroid.mockReturnValue(false);
    expect(getPlaybackCapabilities().canSetVolume).toBe(true);
  });
});
