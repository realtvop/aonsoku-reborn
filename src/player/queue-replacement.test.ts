import { describe, expect, it, vi } from "vitest";
import { getReplacementPlayNextSongs } from "./queue-replacement";

const song = (id: string) => ({ id }) as never;

describe("getReplacementPlayNextSongs", () => {
  it("starts at the selected song for a list replacement", () => {
    const songs = [song("1"), song("2"), song("3")];

    expect(
      getReplacementPlayNextSongs({
        kind: "songList",
        songs,
        index: 1,
        shuffle: false,
      }).map((item) => item.id),
    ).toEqual(["2", "3"]);
  });

  it("preserves shuffle intent when adding the replacement after this song", () => {
    const songs = [song("1"), song("2")];
    const shuffle = vi.fn(() => [...songs].reverse());

    expect(
      getReplacementPlayNextSongs(
        { kind: "songList", songs, shuffle: true },
        shuffle,
      ).map((item) => item.id),
    ).toEqual(["2", "1"]);
    expect(shuffle).toHaveBeenCalledWith(songs);
  });
});
