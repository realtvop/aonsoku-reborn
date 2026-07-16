import { describe, expect, it, vi } from "vitest";
import type { PlayerStatePayload } from "../../preload/types";
import type { NativeAudioControlState } from "../native/audio/service";

vi.mock("../native/audio/ipc", () => ({
  desktopNativeAudioService: {
    getControlState: vi.fn(),
    handleRemoteCommand: vi.fn(),
    emitRemoteCommand: vi.fn(),
    onEvent: vi.fn(),
  },
}));

vi.mock("./playerEvents", () => ({
  sendPlayerEvents: vi.fn(),
}));

vi.mock("./playerState", () => ({
  playerState: {
    value: vi.fn(),
  },
}));

import {
  resolveDesktopPlaybackControlState,
  routeDesktopPlaybackAction,
} from "./playerControls";

const emptyNativeState: NativeAudioControlState = {
  isPlaying: false,
  hasCurrent: false,
  hasNativeQueue: false,
  hasPrevious: false,
  hasNext: false,
};

const rendererState: PlayerStatePayload = {
  isPlaying: true,
  hasPrevious: true,
  hasNext: true,
  hasSonglist: true,
};

describe("desktop playback controls", () => {
  it("uses renderer player state when native audio has no current item", () => {
    expect(
      resolveDesktopPlaybackControlState(emptyNativeState, rendererState),
    ).toEqual(rendererState);
  });

  it("uses native control state when native audio has a loaded item", () => {
    expect(
      resolveDesktopPlaybackControlState(
        {
          isPlaying: false,
          hasCurrent: true,
          hasNativeQueue: true,
          hasPrevious: false,
          hasNext: true,
        },
        rendererState,
      ),
    ).toEqual({
      isPlaying: false,
      hasPrevious: false,
      hasNext: true,
      hasSonglist: true,
    });
  });

  it("does not notify renderer when native audio handles the command", async () => {
    const service = {
      handleRemoteCommand: vi.fn(async () => true),
      emitRemoteCommand: vi.fn(),
    };
    const sendRendererAction = vi.fn();

    await routeDesktopPlaybackAction("skipForward", {
      service,
      sendRendererAction,
    });

    expect(service.handleRemoteCommand).toHaveBeenCalledWith("next");
    expect(service.emitRemoteCommand).not.toHaveBeenCalled();
    expect(sendRendererAction).not.toHaveBeenCalled();
  });

  it("emits contract and legacy renderer commands for fallback", async () => {
    const service = {
      handleRemoteCommand: vi.fn(async () => false),
      emitRemoteCommand: vi.fn(),
    };
    const sendRendererAction = vi.fn();

    await routeDesktopPlaybackAction("skipBackwards", {
      service,
      sendRendererAction,
    });

    expect(service.handleRemoteCommand).toHaveBeenCalledWith("previous");
    expect(service.emitRemoteCommand).toHaveBeenCalledWith("previous");
    expect(sendRendererAction).toHaveBeenCalledWith("skipBackwards");
  });

  it("keeps unsupported legacy actions on the renderer compatibility path", async () => {
    const service = {
      handleRemoteCommand: vi.fn(async () => false),
      emitRemoteCommand: vi.fn(),
    };
    const sendRendererAction = vi.fn();

    await routeDesktopPlaybackAction("toggleRepeat", {
      service,
      sendRendererAction,
    });

    expect(service.handleRemoteCommand).not.toHaveBeenCalled();
    expect(service.emitRemoteCommand).not.toHaveBeenCalled();
    expect(sendRendererAction).toHaveBeenCalledWith("toggleRepeat");
  });
});
