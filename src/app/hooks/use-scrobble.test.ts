import { beforeEach, describe, expect, it, vi } from "vitest";

const { shouldUseNativePlaybackBackend } = vi.hoisted(() => ({
  shouldUseNativePlaybackBackend: vi.fn(),
}));

vi.mock("@/player/playback/backend-factory", () => ({
  shouldUseNativePlaybackBackend,
}));

import { shouldRendererSubmitScrobbles } from "./use-scrobble";

describe("renderer scrobble ownership", () => {
  beforeEach(() => {
    shouldUseNativePlaybackBackend.mockReset();
  });

  it("keeps JS submission for web and Electron fallback playback", () => {
    shouldUseNativePlaybackBackend.mockReturnValue(false);
    expect(shouldRendererSubmitScrobbles()).toBe(true);
  });

  it("defers to native ownership when the native backend is available", () => {
    shouldUseNativePlaybackBackend.mockReturnValue(true);
    expect(shouldRendererSubmitScrobbles()).toBe(false);
  });
});
