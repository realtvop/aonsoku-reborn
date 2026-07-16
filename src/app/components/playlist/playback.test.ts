import { describe, expect, it } from "vitest";
import type { IContextQueue } from "@/types/playerContext";
import { shouldConfirmPlaylistPlayback } from "./playback";

function contextQueue(
  songs: IContextQueue["songs"],
  sourceId: IContextQueue["sourceId"],
): IContextQueue {
  return {
    songs,
    currentIndex: 0,
    sourceId,
    sourceName: null,
  };
}

const song = { id: "song-1" } as IContextQueue["songs"][number];

describe("shouldConfirmPlaylistPlayback", () => {
  it("does not confirm when the context queue is empty", () => {
    expect(
      shouldConfirmPlaylistPlayback(contextQueue([], null), "playlist-2"),
    ).toBe(false);
  });

  it("does not confirm when restarting the current playlist", () => {
    expect(
      shouldConfirmPlaylistPlayback(
        contextQueue([song], { type: "playlist", id: "playlist-1" }),
        "playlist-1",
      ),
    ).toBe(false);
  });

  it("confirms when playing a different playlist", () => {
    expect(
      shouldConfirmPlaylistPlayback(
        contextQueue([song], { type: "playlist", id: "playlist-1" }),
        "playlist-2",
      ),
    ).toBe(true);
  });

  it("confirms when the current queue came from another source", () => {
    expect(
      shouldConfirmPlaylistPlayback(
        contextQueue([song], { type: "album", id: "album-1" }),
        "playlist-1",
      ),
    ).toBe(true);
  });
});
