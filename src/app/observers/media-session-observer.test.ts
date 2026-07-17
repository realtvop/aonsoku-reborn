import type { AonsokuAudioBridge } from "@aonsoku/audio-contract";
import { describe, expect, it, vi } from "vitest";
import { syncNativeRemotePlaybackProjection } from "./media-session-observer";

describe("Electron remote system-media projection", () => {
  it("publishes and clears projection through native audio even when coordination is native-owned", async () => {
    const plugin = {
      updateRemotePlaybackState: vi.fn(async () => {}),
      clearRemotePlaybackState: vi.fn(async () => {}),
    } as unknown as AonsokuAudioBridge;
    const projection = {
      metadata: { title: "Remote track", duration: 180 },
      isPlaying: true,
      position: 12,
      duration: 180,
      targetDeviceId: "remote-device",
      expectedGeneration: 4,
    };

    await syncNativeRemotePlaybackProjection(plugin, projection);
    await syncNativeRemotePlaybackProjection(plugin, null);

    expect(plugin.updateRemotePlaybackState).toHaveBeenCalledWith(projection);
    expect(plugin.clearRemotePlaybackState).toHaveBeenCalledOnce();
  });
});
