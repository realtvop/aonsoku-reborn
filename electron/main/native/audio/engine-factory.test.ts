import { beforeEach, describe, expect, it, vi } from "vitest";
import type { LibMpvNativeBinding } from "./libmpv-binding";
import { LibMpvAudioEngine } from "./libmpv-engine";
import { UnavailableDesktopAudioEngine } from "./unavailable-engine";

const mocks = vi.hoisted(() => ({
  createNativeMpvPlayer: vi.fn(),
  loadLibMpvBinding: vi.fn(),
}));

vi.mock("./libmpv-binding", () => ({
  createNativeMpvPlayer: mocks.createNativeMpvPlayer,
  loadLibMpvBinding: mocks.loadLibMpvBinding,
}));

import { createDesktopAudioEngine } from "./engine-factory";

describe("createDesktopAudioEngine", () => {
  beforeEach(() => {
    mocks.createNativeMpvPlayer.mockReset();
    mocks.loadLibMpvBinding.mockReset();
  });

  it("creates a libmpv engine when the binding loads", () => {
    const binding = {
      createPlayer: vi.fn(),
    } satisfies LibMpvNativeBinding;
    mocks.loadLibMpvBinding.mockReturnValue(binding);

    expect(createDesktopAudioEngine()).toBeInstanceOf(LibMpvAudioEngine);
  });

  it("creates an unavailable engine when the binding cannot load", async () => {
    mocks.loadLibMpvBinding.mockImplementation(() => {
      throw new Error("missing addon");
    });

    const engine = createDesktopAudioEngine();
    const events: unknown[] = [];
    engine.onEvent((event) => events.push(event));

    expect(engine).toBeInstanceOf(UnavailableDesktopAudioEngine);
    await expect(engine.play()).rejects.toMatchObject({
      code: "libmpv-unavailable",
      message: "Desktop native audio is unavailable: missing addon",
    });
    expect(events).toEqual([
      {
        type: "error",
        code: "libmpv-unavailable",
        message: "Desktop native audio is unavailable: missing addon",
      },
    ]);
  });
});
