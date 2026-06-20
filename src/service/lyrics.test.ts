import { beforeEach, describe, expect, it, vi } from "vitest";
import type { SelectedCustomLyrics } from "@/types/playerContext";

const mockPlayerStoreState = {
  settings: {
    lyrics: {
      customServerEnabled: true,
      customServerUrl: "https://lyrics.example.com/api",
      customServerPassword: "",
      preferSyncedLyrics: false,
      selectedCustomLyrics: {},
    },
    privacy: { lrcLibEnabled: true },
  },
};

vi.mock("@/store/player.store", () => ({
  usePlayerStore: {
    getState: () => mockPlayerStoreState,
  },
}));

vi.mock("@/api/httpClient", () => ({
  httpClient: vi.fn(),
}));

vi.mock("@/utils/logger", () => ({
  logger: {
    warn: vi.fn(),
    error: vi.fn(),
    info: vi.fn(),
    debug: vi.fn(),
  },
}));

import {
  CUSTOM_LYRICS_DB_NAME,
  CUSTOM_LYRICS_IDB_PREFIX,
  CUSTOM_LYRICS_STORE_NAME,
  deleteCustomLyricsBodies,
  type GetLyricsData,
  getCustomLyricsBody,
  getCustomLyricsCandidateKey,
  getCustomLyricsSongKey,
  getSelectedCustomLyrics,
  setCustomLyricsBody,
} from "./lyrics";

describe("getCustomLyricsSongKey", () => {
  it("joins path, artist, title, album with unit separator", () => {
    const key = getCustomLyricsSongKey({
      artist: "Artist",
      title: "Title",
      album: "Album",
      path: "/music/song.mp3",
    });
    expect(key).toBe("/music/song.mp3\u001fArtist\u001fTitle\u001fAlbum");
  });

  it("uses empty string for missing optional fields", () => {
    const key = getCustomLyricsSongKey({
      artist: "Artist",
      title: "Title",
    });
    expect(key).toBe("\u001fArtist\u001fTitle\u001f");
  });

  it("produces different keys for different songs", () => {
    const key1 = getCustomLyricsSongKey({
      artist: "A",
      title: "X",
      path: "/a.mp3",
    });
    const key2 = getCustomLyricsSongKey({
      artist: "B",
      title: "Y",
      path: "/b.mp3",
    });
    expect(key1).not.toBe(key2);
  });

  it("produces same key for identical data", () => {
    const data: GetLyricsData = {
      artist: "A",
      title: "T",
      path: "/p",
      album: "Al",
    };
    expect(getCustomLyricsSongKey(data)).toBe(getCustomLyricsSongKey(data));
  });

  it("differentiates songs with same title but different paths", () => {
    const key1 = getCustomLyricsSongKey({
      artist: "Artist",
      title: "Same Title",
      path: "/album1/song.mp3",
    });
    const key2 = getCustomLyricsSongKey({
      artist: "Artist",
      title: "Same Title",
      path: "/album2/song.mp3",
    });
    expect(key1).not.toBe(key2);
  });
});

describe("getCustomLyricsCandidateKey", () => {
  it("returns id when candidate has a truthy id", () => {
    expect(
      getCustomLyricsCandidateKey(
        { id: "abc-123", artist: "A", title: "T", lyrics: "text" },
        0,
      ),
    ).toBe("abc-123");
  });

  it("returns id regardless of index", () => {
    expect(getCustomLyricsCandidateKey({ id: "xyz", lyrics: "text" }, 5)).toBe(
      "xyz",
    );
  });

  it("falls back to index:artist:title when no id", () => {
    expect(
      getCustomLyricsCandidateKey(
        { artist: "Artist", title: "Title", lyrics: "text" },
        2,
      ),
    ).toBe("2:Artist:Title");
  });

  it("uses empty strings for missing artist/title in fallback", () => {
    expect(getCustomLyricsCandidateKey({ lyrics: "text" }, 0)).toBe("0::");
  });

  it("falls back to compound key when id is empty string (falsy)", () => {
    expect(
      getCustomLyricsCandidateKey(
        { id: "", artist: "A", title: "T", lyrics: "text" },
        3,
      ),
    ).toBe("3:A:T");
  });
});

describe("getSelectedCustomLyrics", () => {
  it("returns the entry for the given songKey", () => {
    const entry: SelectedCustomLyrics = {
      key: "cand-key-1",
      title: "Title",
      artist: "Artist",
    };
    const map: Record<string, SelectedCustomLyrics> = {
      "song-key-1": entry,
    };
    expect(getSelectedCustomLyrics(map, "song-key-1")).toBe(entry);
  });

  it("returns undefined when songKey is not in map", () => {
    const map: Record<string, SelectedCustomLyrics> = {
      "song-key-1": { key: "c1" },
    };
    expect(getSelectedCustomLyrics(map, "song-key-2")).toBeUndefined();
  });

  it("returns undefined when map is undefined", () => {
    expect(getSelectedCustomLyrics(undefined, "song-key-1")).toBeUndefined();
  });

  it("returns undefined when map is empty", () => {
    expect(getSelectedCustomLyrics({}, "song-key-1")).toBeUndefined();
  });
});

describe("custom lyrics IDB operations", () => {
  beforeEach(async () => {
    const { createStore, clear } = await import("idb-keyval");
    const store = createStore(
      CUSTOM_LYRICS_DB_NAME,
      CUSTOM_LYRICS_STORE_NAME,
    );
    await clear(store);
  });

  it("round-trips lyrics body with set and get", async () => {
    const songKey = "path\u001fArtist\u001fTitle\u001fAlbum";
    await setCustomLyricsBody(songKey, "Line 1\nLine 2\nLine 3");
    const result = await getCustomLyricsBody(songKey);
    expect(result).toBe("Line 1\nLine 2\nLine 3");
  });

  it("returns undefined for non-existent songKey", async () => {
    const result = await getCustomLyricsBody("non-existent-key");
    expect(result).toBeUndefined();
  });

  it("overwrites existing lyrics body", async () => {
    const songKey = "overwrite-key";
    await setCustomLyricsBody(songKey, "old lyrics");
    await setCustomLyricsBody(songKey, "new lyrics");
    expect(await getCustomLyricsBody(songKey)).toBe("new lyrics");
  });

  it("stores with correct IDB key prefix", async () => {
    const { get } = await import("idb-keyval");
    const { createStore } = await import("idb-keyval");
    const store = createStore(
      CUSTOM_LYRICS_DB_NAME,
      CUSTOM_LYRICS_STORE_NAME,
    );
    const songKey = "test-prefix-key";
    await setCustomLyricsBody(songKey, "some lyrics");
    const stored = await get<string>(
      `${CUSTOM_LYRICS_IDB_PREFIX}${songKey}`,
      store,
    );
    expect(stored).toBe("some lyrics");
  });

  it("deletes specified song keys", async () => {
    await setCustomLyricsBody("key1", "lyrics 1");
    await setCustomLyricsBody("key2", "lyrics 2");
    await setCustomLyricsBody("key3", "lyrics 3");
    await deleteCustomLyricsBodies(["key1", "key3"]);
    expect(await getCustomLyricsBody("key1")).toBeUndefined();
    expect(await getCustomLyricsBody("key2")).toBe("lyrics 2");
    expect(await getCustomLyricsBody("key3")).toBeUndefined();
  });

  it("handles empty array for deletion", async () => {
    await setCustomLyricsBody("key1", "lyrics 1");
    await deleteCustomLyricsBodies([]);
    expect(await getCustomLyricsBody("key1")).toBe("lyrics 1");
  });

  it("handles non-existent keys gracefully", async () => {
    const results = await deleteCustomLyricsBodies(["non-existent"]);
    expect(results).toHaveLength(1);
  });

  it("isolates different song keys", async () => {
    await setCustomLyricsBody("song-a", "lyrics A");
    await setCustomLyricsBody("song-b", "lyrics B");
    expect(await getCustomLyricsBody("song-a")).toBe("lyrics A");
    expect(await getCustomLyricsBody("song-b")).toBe("lyrics B");
  });
});
