import { describe, expect, it } from "vitest";
import { mapNativeRemoteControlCommand } from "./native-remote-control-command";

describe("mapNativeRemoteControlCommand", () => {
  it("maps transport and media commands", () => {
    expect(mapNativeRemoteControlCommand({ type: "play" })).toEqual({
      type: "play",
    });
    expect(mapNativeRemoteControlCommand({ type: "toggle" })).toEqual({
      type: "toggle_play_pause",
    });
    expect(
      mapNativeRemoteControlCommand({ type: "seek", seconds: -4 }),
    ).toEqual({
      type: "seek",
      seconds: 0,
    });
    expect(
      mapNativeRemoteControlCommand({ type: "set_volume", volume: 1.5 }),
    ).toEqual({
      type: "set_volume",
      volume: 1,
    });
    expect(
      mapNativeRemoteControlCommand({ type: "set_shuffle", enabled: false }),
    ).toEqual({
      type: "set_shuffle",
      enabled: false,
    });
    expect(
      mapNativeRemoteControlCommand({ type: "set_repeat", mode: "one" }),
    ).toEqual({
      type: "set_repeat",
      mode: "one",
    });
    expect(mapNativeRemoteControlCommand({ type: "toggle_like" })).toEqual({
      type: "toggle_like",
    });
  });

  it("maps queue commands without changing protocol field names", () => {
    expect(
      mapNativeRemoteControlCommand({
        type: "play_at_index",
        song_ids: ["song-1", "song-2"],
        index: 1,
      }),
    ).toEqual({
      type: "play_at_index",
      song_ids: ["song-1", "song-2"],
      index: 1,
    });
    expect(
      mapNativeRemoteControlCommand({
        type: "add_to_queue_next",
        song_ids: ["song-3"],
      }),
    ).toEqual({
      type: "add_to_queue_next",
      song_ids: ["song-3"],
    });
    expect(
      mapNativeRemoteControlCommand({
        type: "remove_from_queue",
        song_ids: ["song-2"],
      }),
    ).toEqual({
      type: "remove_from_queue",
      song_ids: ["song-2"],
    });
    expect(
      mapNativeRemoteControlCommand({ type: "reorder_queue", from: 2, to: 0 }),
    ).toEqual({
      type: "reorder_queue",
      from: 2,
      to: 0,
    });
    expect(mapNativeRemoteControlCommand({ type: "clear_queue" })).toEqual({
      type: "clear_queue",
    });
  });

  it("maps play intents and rejects malformed commands", () => {
    expect(
      mapNativeRemoteControlCommand({
        type: "play_album",
        album_id: "album-1",
        index: 3,
        shuffle: true,
      }),
    ).toEqual({
      type: "play_album",
      album_id: "album-1",
      index: 3,
      shuffle: true,
    });
    expect(
      mapNativeRemoteControlCommand({
        type: "play_playlist",
        playlist_id: "playlist-1",
      }),
    ).toEqual({
      type: "play_playlist",
      playlist_id: "playlist-1",
      index: undefined,
      shuffle: undefined,
    });
    expect(
      mapNativeRemoteControlCommand({ type: "seek", seconds: "4" }),
    ).toBeNull();
    expect(
      mapNativeRemoteControlCommand({
        type: "play_at_index",
        song_ids: ["song-1", 2],
        index: 0,
      }),
    ).toBeNull();
  });
});
