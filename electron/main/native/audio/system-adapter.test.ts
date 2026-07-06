import { describe, expect, it, vi } from "vitest";
import {
  clampUnitVolume,
  MacOsSystemAudioAdapter,
  MemorySystemAudioAdapter,
  createDesktopSystemAudioAdapter,
} from "./system-adapter";

describe("desktop system audio adapters", () => {
  it("clamps unit volume values", () => {
    expect(clampUnitVolume(-1)).toBe(0);
    expect(clampUnitVolume(0.4)).toBe(0.4);
    expect(clampUnitVolume(2)).toBe(1);
    expect(clampUnitVolume(Number.NaN)).toBe(1);
  });

  it("uses a memory-backed fallback outside macOS", async () => {
    const adapter = createDesktopSystemAudioAdapter({ platform: "linux" });

    expect(adapter).toBeInstanceOf(MemorySystemAudioAdapter);
    await expect(adapter.setSystemVolume(0.35)).resolves.toEqual({
      volume: 0.35,
    });
    await expect(adapter.getSystemVolume()).resolves.toEqual({
      volume: 0.35,
    });
  });

  it("maps macOS volume calls through osascript", async () => {
    const scripts: string[] = [];
    const runAppleScript = vi.fn(async (script: string) => {
      scripts.push(script);
      return script.startsWith("output volume") ? "42\n" : "";
    });
    const adapter = new MacOsSystemAudioAdapter({ runAppleScript });

    await expect(adapter.setSystemVolume(0.427)).resolves.toEqual({
      volume: 0.42,
    });

    expect(scripts).toEqual([
      "set volume output volume 43",
      "output volume of (get volume settings)",
    ]);
  });

  it("falls back to the requested value when macOS volume readback fails", async () => {
    const adapter = new MacOsSystemAudioAdapter({
      runAppleScript: async () => "not-a-number",
    });

    await expect(adapter.setSystemVolume(0.25)).resolves.toEqual({
      volume: 0.25,
    });
  });
});
