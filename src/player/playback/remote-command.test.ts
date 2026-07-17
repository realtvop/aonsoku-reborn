import { describe, expect, it, vi } from "vitest";
import { handlePlaybackRemoteCommand } from "./remote-command";

function createContext(isPlaying: boolean) {
  const state = { isPlaying };

  return {
    context: {
      isPlaying: () => state.isPlaying,
      togglePlayPause: vi.fn(() => {
        state.isPlaying = !state.isPlaying;
      }),
      stop: vi.fn(),
      playNextSong: vi.fn(),
      playPrevSong: vi.fn(),
      seek: vi.fn(),
      starCurrentSong: vi.fn(),
    },
    state,
  };
}

describe("handlePlaybackRemoteCommand", () => {
  it("maps play and pause commands through authoritative player state", () => {
    const { context, state } = createContext(false);

    handlePlaybackRemoteCommand({ command: "play" }, context);
    handlePlaybackRemoteCommand({ command: "play" }, context);
    expect(context.togglePlayPause).toHaveBeenCalledTimes(1);
    expect(state.isPlaying).toBe(true);

    handlePlaybackRemoteCommand({ command: "pause" }, context);
    handlePlaybackRemoteCommand({ command: "pause" }, context);
    expect(context.togglePlayPause).toHaveBeenCalledTimes(2);
    expect(state.isPlaying).toBe(false);
  });

  it("maps toggle, track, and seek commands", () => {
    const { context } = createContext(false);

    handlePlaybackRemoteCommand({ command: "togglePlayPause" }, context);
    handlePlaybackRemoteCommand({ command: "next" }, context);
    handlePlaybackRemoteCommand({ command: "previous" }, context);
    handlePlaybackRemoteCommand({ command: "seek", position: -12 }, context);

    expect(context.togglePlayPause).toHaveBeenCalledTimes(1);
    expect(context.playNextSong).toHaveBeenCalledTimes(1);
    expect(context.playPrevSong).toHaveBeenCalledTimes(1);
    expect(context.seek).toHaveBeenCalledWith(0);
  });

  it("maps stop to clearing the player", () => {
    const { context } = createContext(true);

    handlePlaybackRemoteCommand({ command: "stop" }, context);

    expect(context.stop).toHaveBeenCalledOnce();
  });

  it("maps like command to starCurrentSong", () => {
    const { context } = createContext(true);

    handlePlaybackRemoteCommand({ command: "like" }, context);

    expect(context.starCurrentSong).toHaveBeenCalledTimes(1);
  });
});
