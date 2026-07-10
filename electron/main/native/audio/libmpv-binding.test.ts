import { describe, expect, it, vi } from "vitest";
import type { LibMpvNativeBinding } from "./libmpv-binding";
import {
  createNativeMpvPlayer,
  getLibMpvAddonCandidates,
  libMpvPlatformKey,
  libMpvRuntimeAddonPath,
  loadLibMpvBinding,
} from "./libmpv-binding";
import type { MpvPlayerEvent } from "./mpv-player";

describe("libmpv native binding loader", () => {
  it("builds deterministic addon candidate paths", () => {
    expect(libMpvPlatformKey("darwin", "arm64")).toBe("darwin-arm64");
    expect(
      libMpvRuntimeAddonPath("/App/Contents/Resources", {
        platform: "darwin",
        arch: "arm64",
      }),
    ).toBe(
      "/App/Contents/Resources/native-audio/darwin-arm64/aonsoku_libmpv.node",
    );

    expect(
      getLibMpvAddonCandidates({
        addonPath: "/custom/aonsoku_libmpv.node",
        resourcesPath: "/App/Contents/Resources",
        cwd: "/repo",
        platform: "darwin",
        arch: "arm64",
      }),
    ).toEqual([
      "/custom/aonsoku_libmpv.node",
      "/App/Contents/Resources/native-audio/darwin-arm64/aonsoku_libmpv.node",
      "/repo/resources/native-audio/darwin-arm64/aonsoku_libmpv.node",
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

  it("can prefer the freshly built source addon during development", () => {
    const candidates = getLibMpvAddonCandidates({
      cwd: process.cwd(),
      preferSourceBuild: true,
      resourcesPath: "/App/Contents/Resources",
      platform: "darwin",
      arch: "arm64",
    });

    expect(candidates[0]).toMatch(
      /electron\/main\/native\/audio\/libmpv\/build\/Release\/aonsoku_libmpv\.node$/u,
    );
  });

  it("throws a diagnostic error when the addon cannot be loaded", () => {
    expect(() =>
      loadLibMpvBinding({
        addonPath: "/missing/aonsoku_libmpv.node",
        exists: () => false,
        platform: "linux",
        arch: "x64",
      }),
    ).toThrow(/Platform key: linux-x64/u);
  });

  it("validates packaged runtime manifests before requiring the addon", () => {
    expect(() =>
      loadLibMpvBinding({
        addonPath: "/runtime/aonsoku_libmpv.node",
        exists: (candidate) =>
          candidate === "/runtime/aonsoku_libmpv.node" ||
          candidate === "/runtime/manifest.json",
        readTextFile: () =>
          JSON.stringify({
            schemaVersion: 1,
            platform: "darwin",
            arch: "arm64",
            platformKey: "darwin-arm64",
            addon: "aonsoku_libmpv.node",
            libraries: ["libmpv.2.dylib"],
          }),
        require: vi.fn() as unknown as NodeJS.Require,
      }),
    ).toThrow(/libmpv runtime manifest is incomplete/u);
  });

  it("adds the runtime directory to PATH before loading Windows addons", () => {
    const binding = {
      createPlayer: vi.fn(),
    } satisfies LibMpvNativeBinding;
    const originalPath = process.env.PATH;
    const requireNative = vi.fn(() => binding);

    try {
      process.env.PATH = "C:\\Windows\\System32";

      expect(
        loadLibMpvBinding({
          addonPath: "/runtime/win32-x64/aonsoku_libmpv.node",
          require: requireNative as unknown as NodeJS.Require,
          exists: (candidate) => candidate.endsWith(".node"),
          platform: "win32",
          arch: "x64",
        }),
      ).toBe(binding);
      expect(process.env.PATH?.split(";")[0]).toBe("/runtime/win32-x64");
    } finally {
      process.env.PATH = originalPath;
    }
  });
});

describe("native mpv player adapter", () => {
  it("forwards player methods and events through the typed interface", () => {
    let eventCallback: ((event: MpvPlayerEvent) => void) | null = null;
    const emitNativeEvent = (event: MpvPlayerEvent) => {
      if (!eventCallback) {
        throw new Error("native event callback was not registered");
      }

      eventCallback(event);
    };
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
    emitNativeEvent({
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
