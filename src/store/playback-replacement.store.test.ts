import { beforeEach, describe, expect, it } from "vitest";
import { usePlaybackReplacementStore } from "./playback-replacement.store";

describe("pending queue replacement", () => {
  beforeEach(() => usePlaybackReplacementStore.getState().reset());

  it.each([null, "device-a"])(
    "consumes the request only once on its original target (%s)",
    (targetDeviceId) => {
      const request = {
        kind: "song" as const,
        song: { id: "replacement" } as never,
        targetDeviceId,
      };
      const store = usePlaybackReplacementStore.getState();
      store.show(request);
      expect(store.takeRequest(targetDeviceId)).toBe(request);
      expect(store.takeRequest(targetDeviceId)).toBeNull();
      expect(usePlaybackReplacementStore.getState().open).toBe(false);
    },
  );

  it.each([
    ["device-a", "device-b"],
    ["device-a", null],
    [null, "device-a"],
  ])(
    "cancels a replacement when the target changes from %s to %s",
    (original, current) => {
      const store = usePlaybackReplacementStore.getState();
      store.show({
        kind: "song",
        song: { id: "replacement" } as never,
        targetDeviceId: original,
      });
      expect(store.takeRequest(current)).toBeNull();
      expect(usePlaybackReplacementStore.getState().request).toBeNull();
      expect(usePlaybackReplacementStore.getState().open).toBe(false);
    },
  );
});
