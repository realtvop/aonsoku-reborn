import { beforeEach, describe, expect, it, vi } from "vitest";
import { libraryAccountKey } from "@/lib/library-owner";
import { _resetLibraryDbForTests, libraryDb } from "@/store/library-db";
import {
  normalizeAlbum,
  replaceOwnedAlbums,
  sampleOwnedAlbums,
} from "./owned-albums";

const owner = libraryAccountKey({
  url: "https://server.test",
  username: "alice",
});
const album = (id: string) => ({ id, name: id, artist: "Artist" });

describe("account-owned carousel candidates", () => {
  beforeEach(_resetLibraryDbForTests);

  it("samples at most ten unique albums and excludes unowned or other-account rows", async () => {
    await replaceOwnedAlbums(
      libraryDb,
      Array.from({ length: 30 }, (_, i) => album(`a${i}`)),
      owner,
      new AbortController().signal,
    );
    await libraryDb.albums.put(normalizeAlbum(album("legacy")));
    await libraryDb.albums.put({
      ...normalizeAlbum(album("foreign")),
      libraryOwner: "other",
    });
    const result = await sampleOwnedAlbums(libraryDb, owner, 10, () => 0.25);
    expect(result).toHaveLength(10);
    expect(new Set(result.map((a) => a.id)).size).toBe(10);
    expect(result.every((a) => a.id.startsWith("a"))).toBe(true);
    expect(await sampleOwnedAlbums(libraryDb, "unknown", 10)).toEqual([]);
  });

  it("replaces empty libraries and rolls back partially written albums on cancellation", async () => {
    await replaceOwnedAlbums(
      libraryDb,
      [album("original")],
      owner,
      new AbortController().signal,
    );
    const controller = new AbortController();
    const original = libraryDb.albums.bulkPut.bind(libraryDb.albums);
    const spy = vi
      .spyOn(libraryDb.albums, "bulkPut")
      .mockImplementationOnce((...args) =>
        original(...args).then((result) => {
          controller.abort();
          return result;
        }),
      );
    try {
      await expect(
        replaceOwnedAlbums(
          libraryDb,
          Array.from({ length: 2001 }, (_, i) => album(`new${i}`)),
          owner,
          controller.signal,
        ),
      ).rejects.toThrow();
    } finally {
      spy.mockRestore();
    }
    expect(
      (await sampleOwnedAlbums(libraryDb, owner, 10)).map((a) => a.id),
    ).toEqual(["original"]);
    await replaceOwnedAlbums(
      libraryDb,
      [],
      owner,
      new AbortController().signal,
    );
    expect(await libraryDb.albums.count()).toBe(0);
  });

  it("keeps primary/fallback identity stable while isolating users", () => {
    expect(
      libraryAccountKey({
        primaryUrl: "https://server.test/",
        url: "http://lan",
        username: "alice",
      }),
    ).toBe(owner);
    expect(
      libraryAccountKey({ url: "https://server.test", username: "bob" }),
    ).not.toBe(owner);
  });
});
