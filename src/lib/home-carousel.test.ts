import { beforeEach, describe, expect, it, vi } from "vitest";

const native = vi.hoisted(() => ({ getAlbums: vi.fn() }));
vi.mock("@/native/data/facade", () => ({
  isNativeDataAvailable: () => true,
  AonsokuNativeData: native,
}));
import { localCarousel } from "./home-carousel";

describe("native carousel ownership", () => {
  beforeEach(() => native.getAlbums.mockReset());

  it("accepts only the configured account's native metadata, including its fallback address", async () => {
    const items = [{ id: "album", name: "Album", artist: "Artist" }];
    native.getAlbums.mockResolvedValue({ items, libraryOwner: "foreign" });
    expect((await localCarousel("primary", "active")).list).toEqual([]);
    native.getAlbums.mockResolvedValue({ items, libraryOwner: "fallback" });
    expect(
      (await localCarousel("primary", "active", 10, "fallback")).list.map(
        (a) => a.id,
      ),
    ).toEqual(["album"]);
    expect(native.getAlbums).toHaveBeenLastCalledWith({
      limit: 10,
      offset: 0,
      sortBy: "random",
    });
  });

  it("does not treat legacy native metadata without an owner as account-scoped", async () => {
    native.getAlbums.mockResolvedValue({ items: [{ id: "unowned" }] });
    expect((await localCarousel("primary", "active")).list).toEqual([]);
  });
});
