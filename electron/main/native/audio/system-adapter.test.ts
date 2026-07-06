import { describe, expect, it } from "vitest";
import {
  MacOsSystemAudioAdapter,
  MemorySystemAudioAdapter,
  createDesktopSystemAudioAdapter,
} from "./system-adapter";

describe("desktop system audio adapters", () => {
  it("uses a memory-backed fallback outside macOS", () => {
    const adapter = createDesktopSystemAudioAdapter({ platform: "linux" });

    expect(adapter).toBeInstanceOf(MemorySystemAudioAdapter);
  });

  it("uses the macOS adapter on darwin", () => {
    const adapter = createDesktopSystemAudioAdapter({ platform: "darwin" });

    expect(adapter).toBeInstanceOf(MacOsSystemAudioAdapter);
  });

  it("tracks HUD and like state without touching OS volume", async () => {
    const adapter = new MacOsSystemAudioAdapter();

    await adapter.setVolumeHUDEnabled(false);
    await adapter.setLikeActive(true);

    expect(adapter.volumeHUDEnabledForTest).toBe(false);
    expect(adapter.likeActiveForTest).toBe(true);
  });
});
