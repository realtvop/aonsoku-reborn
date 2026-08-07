import { afterEach, describe, expect, it, vi } from "vitest";
import type { AonsokuNativeDataPlugin } from "@/native/data";
import {
  _resetNativeImageCacheAdapter,
  getNativeImageCacheAdapter,
  IosNativeImageCacheAdapter,
} from "./native-image-cache-adapter";

const mocks = vi.hoisted(() => ({
  getNativeDataAvailability: vi.fn(),
}));

vi.mock("@/native/data", () => ({
  getNativeDataAvailability: mocks.getNativeDataAvailability,
}));

afterEach(() => {
  _resetNativeImageCacheAdapter();
  mocks.getNativeDataAvailability.mockReset();
});

describe("getNativeImageCacheAdapter", () => {
  it("upgrades after the native data plugin becomes available", () => {
    mocks.getNativeDataAvailability.mockReturnValue({
      available: false,
      reason: "missing-plugin",
    });
    expect(getNativeImageCacheAdapter()).not.toBeInstanceOf(
      IosNativeImageCacheAdapter,
    );

    const plugin = {} as AonsokuNativeDataPlugin;
    mocks.getNativeDataAvailability.mockReturnValue({
      available: true,
      plugin,
    });
    expect(getNativeImageCacheAdapter()).toBeInstanceOf(
      IosNativeImageCacheAdapter,
    );
  });
});
