import { describe, expect, it } from "vitest";
import { LanControlMessageType } from "@/types/lanControl";
import { mapLanControlToRemoteCommand } from "./use-device-playback-actions";

function playerState(overrides: { isShuffleActive?: boolean; loopState?: number } = {}) {
  return {
    isShuffleActive: false,
    loopState: 0,
    ...overrides,
  };
}

describe("mapLanControlToRemoteCommand", () => {
  it("maps transport controls to coordination remote commands", () => {
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.PLAY_PAUSE,
        undefined,
        () => playerState(),
      ),
    ).toEqual({ type: "toggle_play_pause" });
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.NEXT,
        undefined,
        () => playerState(),
      ),
    ).toEqual({ type: "next" });
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.SEEK,
        { seconds: 42 },
        () => playerState(),
      ),
    ).toEqual({ type: "seek", seconds: 42 });
  });

  it("maps queue and play intents without changing protocol shape", () => {
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.PLAY_ALBUM_SHUFFLE,
        { albumId: "album-1", songIndex: 3 },
        () => playerState(),
      ),
    ).toEqual({
      type: "play_album",
      album_id: "album-1",
      index: 3,
      shuffle: true,
    });
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.ADD_TO_QUEUE,
        { songIds: ["song-1", "song-2"] },
        () => playerState(),
      ),
    ).toEqual({
      type: "add_to_queue_last",
      song_ids: ["song-1", "song-2"],
    });
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.PLAY_AT_INDEX,
        { songIds: ["song-1", "song-2"], index: 1 },
        () => playerState(),
      ),
    ).toEqual({
      type: "play_at_index",
      song_ids: ["song-1", "song-2"],
      index: 1,
    });
  });

  it("derives shuffle and repeat commands from current player state", () => {
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.TOGGLE_SHUFFLE,
        undefined,
        () => playerState({ isShuffleActive: true }),
      ),
    ).toEqual({ type: "set_shuffle", enabled: false });
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.TOGGLE_REPEAT,
        undefined,
        () => playerState({ loopState: 0 }),
      ),
    ).toEqual({ type: "set_repeat", mode: "all" });
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.TOGGLE_REPEAT,
        undefined,
        () => playerState({ loopState: 1 }),
      ),
    ).toEqual({ type: "set_repeat", mode: "one" });
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.TOGGLE_REPEAT,
        undefined,
        () => playerState({ loopState: 2 }),
      ),
    ).toEqual({ type: "set_repeat", mode: "off" });
  });

  it("returns null for malformed commands", () => {
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.SEEK,
        { seconds: "42" },
        () => playerState(),
      ),
    ).toBeNull();
    expect(
      mapLanControlToRemoteCommand(
        LanControlMessageType.PLAY_SONG,
        {},
        () => playerState(),
      ),
    ).toBeNull();
  });
});
