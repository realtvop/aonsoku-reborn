import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  class MockNativeQueueController {
    static shouldThrow = false;
    readonly kind = "native";
    readonly dispose = vi.fn();

    constructor() {
      if (MockNativeQueueController.shouldThrow) {
        throw new Error("native unavailable");
      }
    }
  }

  class MockWebQueueController {
    readonly kind = "web";
    readonly dispose = vi.fn();
  }

  return {
    getPlaybackCapabilities: vi.fn(),
    getNativeAudioPluginAvailability: vi.fn(),
    logger: {
      error: vi.fn(),
    },
    MockNativeQueueController,
    MockWebQueueController,
  };
});

vi.mock("@/utils/capabilities", () => ({
  getPlaybackCapabilities: mocks.getPlaybackCapabilities,
}));

vi.mock("@/native/audio", () => ({
  getNativeAudioPluginAvailability: mocks.getNativeAudioPluginAvailability,
}));

vi.mock("@/utils/logger", () => ({
  logger: mocks.logger,
}));

vi.mock("./native-controller", () => ({
  NativeQueueController: mocks.MockNativeQueueController,
}));

vi.mock("./web-controller", () => ({
  WebQueueController: mocks.MockWebQueueController,
}));

import {
  getNativeQueueController,
  getQueueController,
  resetQueueController,
} from "./index";
import { NativeQueueController } from "./native-controller";
import { WebQueueController } from "./web-controller";

describe("queue controller selection", () => {
  beforeEach(() => {
    mocks.getPlaybackCapabilities.mockReturnValue({
      supportsNativePlayback: false,
    });
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: true,
      plugin: {},
    });
    mocks.MockNativeQueueController.shouldThrow = false;
    vi.clearAllMocks();
    resetQueueController();
  });

  afterEach(() => {
    resetQueueController();
  });

  it("uses the web controller when native playback is unavailable", () => {
    const controller = getQueueController();

    expect(controller).toBeInstanceOf(WebQueueController);
    expect(getNativeQueueController()).toBeNull();
  });

  it("uses the native controller when native playback is supported", () => {
    mocks.getPlaybackCapabilities.mockReturnValue({
      supportsNativePlayback: true,
    });

    const controller = getQueueController();

    expect(controller).toBeInstanceOf(NativeQueueController);
    expect(getNativeQueueController()).toBe(controller);
  });

  it("falls back to the web controller when native construction fails", () => {
    mocks.getPlaybackCapabilities.mockReturnValue({
      supportsNativePlayback: true,
    });
    mocks.MockNativeQueueController.shouldThrow = true;

    const controller = getQueueController();

    expect(controller).toBeInstanceOf(WebQueueController);
    expect(mocks.logger.error).toHaveBeenCalledWith(
      "[QueueController] Native controller unavailable, falling back to web",
      expect.any(Error),
    );
  });

  it("uses the web controller when the desktop health handshake fails", () => {
    mocks.getPlaybackCapabilities.mockReturnValue({
      supportsNativePlayback: true,
    });
    mocks.getNativeAudioPluginAvailability.mockReturnValue({
      available: false,
      reason: "unhealthy-plugin",
      message: "addon unavailable",
    });

    expect(getQueueController()).toBeInstanceOf(WebQueueController);
  });
});
