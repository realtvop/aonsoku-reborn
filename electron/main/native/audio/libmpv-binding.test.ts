import { describe, expect, it, vi } from "vitest";
import {
  createNativeMpvPlayer,
  getLibMpvAddonCandidates,
  libMpvPlatformKey,
  loadLibMpvBinding,
} from "./libmpv-binding";
import type { LibMpvNativeBinding } from "./libmpv-binding";
import type { MpvPlayerEvent } from "./mpv-player";

describe("libmpv native binding loader", () => {
  it("builds deterministic addon candidate paths", () => {
    const platformKey = libMpvPlatformKey();

    expect(libMpvPlatformKey("darwin", "arm64")).toBe("darwin-arm64");

    expect(
      getLibMpvAddonCandidates({
        addonPath: "/custom/aonsoku_libmpv.node",
        resourcesPath: "/App/Contents/Resources",
        cwd: "/repo",
      }),
    ).toEqual([
      "/custom/aonsoku_libmpv.node",
      `/App/Contents/Resources/native-audio/${platformKey}/aonsoku_libmpv.node`,
      `/repo/resources/native-audio/${platformKey}/aonsoku_libmpv.node`,
      expect.stringMatching(
        /electron\/main\/native\/audio\/libmpv\/build\/Release\/aonsoku_libmpv\.node$/u,
      ),
    ]);
  });

  it("loads the first existing native addon candidate", () => {
    const binding = {
      createPlayer: vi.fn(),
    } satisfies LibMpvNativeBinding;
    const requireNative = vi.fn(() => binding);

    expect(
      loadLibMpvBinding({
        addonPath: "/custom/aonsoku_libmpv.node",
        require: requireNative as unknown as NodeJS.Require,
        exists: (candidate) => candidate === "/custom/aonsoku_libmpv.node",
      }),
    ).toBe(binding);
    expect(requireNative).toHaveBeenCalledWith("/custom/aonsoku_libmpv.node");
  });

  it("throws a diagnostic error when the addon cannot be loaded", () => {
    expect(() =>
      loadLibMpvBinding({
        addonPath: "/missing/aonsoku_libmpv.node",
        exists: () => false,
      }),
    ).toThrow(/Unable to load the Aonsoku libmpv native addon/u);
  });
});

describe("native mpv player adapter", () => {
  it("forwards player methods and events through the typed interface", () => {
    let eventCallback: ((event: MpvPlayerEvent) => void) | null = null;
    const nativePlayer = {
      setEventCallback: vi.fn((listener) => {
        eventCallback = listener;
      }),
      initialize: vi.fn(),
      command: vi.fn(),
      setProperty: vi.fn(),
      observeProperty: vi.fn(),
      destroy: vi.fn(),
    };
    const binding = {
      createPlayer: () => nativePlayer,
    } satisfies LibMpvNativeBinding;

    const player = createNativeMpvPlayer(binding);
    const listener = vi.fn();
    player.onEvent(listener);

    player.initialize({ options: { idle: "yes" } });
    player.command(["loadfile", "/tmp/song.mp3", "replace"]);
    player.setProperty("pause", false);
    player.observeProperty("time-pos", "number");
    eventCallback?.({
      type: "property-change",
      name: "time-pos",
      data: 5,
    });
    player.destroy();

    expect(nativePlayer.initialize).toHaveBeenCalledWith({
      options: { idle: "yes" },
    });
    expect(nativePlayer.command).toHaveBeenCalledWith([
      "loadfile",
      "/tmp/song.mp3",
      "replace",
    ]);
    expect(nativePlayer.setProperty).toHaveBeenCalledWith("pause", false);
    expect(nativePlayer.observeProperty).toHaveBeenCalledWith(
      "time-pos",
      "number",
    );
    expect(listener).toHaveBeenCalledWith({
      type: "property-change",
      name: "time-pos",
      data: 5,
    });
    expect(nativePlayer.destroy).toHaveBeenCalledTimes(1);
  });
});
