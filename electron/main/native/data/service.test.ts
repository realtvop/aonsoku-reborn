import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  stores: new Map<string, Record<string, unknown>>(),
  request: vi.fn(),
}));

vi.mock("electron", () => ({
  app: { getPath: () => "/tmp/aonsoku-native-data-test" },
}));

vi.mock("../../core/store", () => ({
  AonsokuStore: class {
    private data: Record<string, unknown>;
    constructor(options: { name: string; defaults?: Record<string, unknown> }) {
      this.data = structuredClone(options.defaults ?? {});
      mocks.stores.set(options.name, this.data);
    }
    get(key: string) {
      return this.data[key];
    }
    set(keyOrValues: string | Record<string, unknown>, value?: unknown) {
      if (typeof keyOrValues === "string") this.data[keyOrValues] = value;
      else Object.assign(this.data, keyOrValues);
    }
  },
}));

const { DesktopNativeDataService } = await import("./service");

function response(data: Record<string, unknown>) {
  return { count: 0, data };
}

describe("DesktopNativeDataService", () => {
  beforeEach(() => {
    mocks.stores.clear();
    mocks.request.mockReset();
  });

  it("syncs the complete library in the main process and serves queries", async () => {
    mocks.request.mockImplementation(async ({ path }: { path: string }) => {
      if (path.includes("getGenres"))
        return response({ genres: { genre: [{ value: "Rock" }] } });
      if (path.includes("getPlaylists"))
        return response({
          playlists: { playlist: [{ id: "p1", name: "Mix" }] },
        });
      if (path.includes("getStarred"))
        return response({ starred2: { song: [] } });
      if (path.includes("getArtists"))
        return response({
          artists: { index: [{ artist: [{ id: "ar1", name: "Artist" }] }] },
        });
      if (path.includes("getAlbumList"))
        return response({
          albumList2: {
            album: [{ id: "al1", name: "Album", artist: "Artist" }],
          },
        });
      if (path.includes("search3"))
        return response({
          searchResult3: {
            song: [
              {
                id: "s1",
                title: "Song",
                artist: "Artist",
                album: "Album",
                albumId: "al1",
                duration: 120,
              },
            ],
          },
        });
      throw new Error(`Unexpected request: ${path}`);
    });

    const events: string[] = [];
    const service = new DesktopNativeDataService(
      {
        request: mocks.request,
        getCredentials: () => ({ serverType: "navidrome" }),
      } as never,
      (event) => events.push(event),
    );

    await service.syncAll({ includeFullSongs: true });

    expect(service.getArtists({ limit: 10, offset: 0 }).items).toHaveLength(1);
    expect(service.getAlbums({ limit: 10, offset: 0 }).items).toHaveLength(1);
    expect(service.getSongs({ limit: 10, offset: 0 }).items).toHaveLength(1);
    expect(service.getAlbum({ id: "al1" })?.song).toHaveLength(1);
    expect(events).toContain("dataChanged");
    expect(service.getSyncState()).toMatchObject({
      phase: "done",
      isSyncing: false,
      progress: 1,
    });
  });

  it("resolves stored covers to local file URIs", async () => {
    const service = new DesktopNativeDataService(
      { request: mocks.request } as never,
      () => {},
    );
    await service.storeCoverImage({
      coverArtId: "mpris-cover",
      dataBase64: Buffer.from("cover").toString("base64"),
      contentType: "image/jpeg",
      coverSize: "300",
    });

    const uri = service.resolveCoverFileUri("mpris-cover");
    expect(uri).toMatch(/^file:\/\//);
    expect(uri).toContain("/aonsoku-native-data-test/CoverCache/");
    expect(service.resolveCoverFileUri("missing-cover")).toBeUndefined();
  });
});
