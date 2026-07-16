import { beforeEach, describe, expect, it, vi } from "vitest";
import type { LibMpvNativeBinding } from "./libmpv-binding";
import { LibMpvAudioEngine } from "./libmpv-engine";
import { UnavailableDesktopAudioEngine } from "./unavailable-engine";

const mocks = vi.hoisted(() => ({
  createNativeMpvPlayer: vi.fn(),
  loadLibMpvBinding: vi.fn(),
  libMpvPlatformKey: vi.fn(() => "darwin-arm64"),
  LibMpvBindingLoadError: class LibMpvBindingLoadError extends Error {
    readonly code = "libmpv-addon-unavailable";
    readonly searchedPaths: string[];
    readonly platformKey: string;

    constructor(searchedPaths: string[], platformKey: string) {
      super("Unable to load the Aonsoku libmpv native addon.");
      this.name = "LibMpvBindingLoadError";
      this.searchedPaths = searchedPaths;
      this.platformKey = platformKey;
    }
  },
}));

vi.mock("./libmpv-binding", () => ({
  createNativeMpvPlayer: mocks.createNativeMpvPlayer,
  LibMpvBindingLoadError: mocks.LibMpvBindingLoadError,
  libMpvPlatformKey: mocks.libMpvPlatformKey,
  loadLibMpvBinding: mocks.loadLibMpvBinding,
}));

import { createDesktopAudioEngine } from "./engine-factory";

describe("createDesktopAudioEngine", () => {
  beforeEach(() => {
    mocks.createNativeMpvPlayer.mockReset();
    mocks.libMpvPlatformKey.mockClear();
    mocks.loadLibMpvBinding.mockReset();
  });

  it("creates a libmpv engine when the binding loads", () => {
    const binding = {
      createPlayer: vi.fn(),
    } satisfies LibMpvNativeBinding;
    mocks.loadLibMpvBinding.mockReturnValue(binding);

    const engine = createDesktopAudioEngine();

    expect(engine).toBeInstanceOf(LibMpvAudioEngine);
    expect(engine.getDiagnostics?.()).toEqual({
      backend: "libmpv",
      status: "available",
      platformKey: "darwin-arm64",
    });
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

  it("preserves addon loader diagnostics for unavailable engines", async () => {
    mocks.loadLibMpvBinding.mockImplementation(() => {
      throw new mocks.LibMpvBindingLoadError(
        ["/missing/aonsoku_libmpv.node"],
        "linux-x64",
      );
    });

    const engine = createDesktopAudioEngine();

    expect(engine).toBeInstanceOf(UnavailableDesktopAudioEngine);
    expect(engine.getDiagnostics?.()).toEqual({
      backend: "libmpv",
      status: "unavailable",
      code: "libmpv-addon-unavailable",
      message: "Unable to load the Aonsoku libmpv native addon.",
      platformKey: "linux-x64",
      searchedPaths: ["/missing/aonsoku_libmpv.node"],
    });
  });
});
