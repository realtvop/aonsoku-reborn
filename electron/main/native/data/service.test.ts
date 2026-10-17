import { rm } from "node:fs/promises";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  stores: new Map<string, Record<string, unknown>>(),
  request: vi.fn(),
  downloadBinary: vi.fn(),
  testRoot: `/tmp/aonsoku-native-data-test-${process.pid}`,
}));

vi.mock("electron", () => ({
  app: { getPath: () => mocks.testRoot },
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
  beforeEach(async () => {
    await rm(mocks.testRoot, { recursive: true, force: true });
    mocks.stores.clear();
    mocks.request.mockReset();
    mocks.downloadBinary.mockReset();
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
    expect(uri).toContain(`${mocks.testRoot}/CoverCache/`);
    expect(service.resolveCoverFileUri("missing-cover")).toBeUndefined();
  });

  it("deduplicates cover downloads and upgrades behind a smaller request", async () => {
    const downloads: Array<{
      resolve: (value: { data: Buffer; contentType: string }) => void;
    }> = [];
    mocks.downloadBinary.mockImplementation(
      () =>
        new Promise((resolve) => {
          downloads.push({ resolve });
        }),
    );
    const service = new DesktopNativeDataService(
      { downloadBinary: mocks.downloadBinary } as never,
      () => {},
    );

    const small = service.downloadCoverImage({
      coverArtId: "shared-cover",
      size: "100",
    });
    await vi.waitFor(() => expect(downloads).toHaveLength(1));
    const large = service.downloadCoverImage({
      coverArtId: "shared-cover",
      size: "700",
    });
    downloads[0].resolve({
      data: Buffer.from("small"),
      contentType: "image/jpeg",
    });
    await small;
    await vi.waitFor(() => expect(downloads).toHaveLength(2));

    const medium = service.downloadCoverImage({
      coverArtId: "shared-cover",
      size: "300",
    });
    downloads[1].resolve({
      data: Buffer.from("large"),
      contentType: "image/jpeg",
    });
    const [largeResult, mediumResult] = await Promise.all([large, medium]);
    await service.storeCoverImage({
      coverArtId: "shared-cover",
      dataBase64: Buffer.from("late small").toString("base64"),
      contentType: "image/jpeg",
      coverSize: "100",
    });

    expect(mocks.downloadBinary).toHaveBeenCalledTimes(2);
    expect(largeResult.file?.coverSize).toBe("700");
    expect(mediumResult.file?.coverSize).toBe("700");
    await expect(
      service.readCoverWithMeta("shared-cover"),
    ).resolves.toMatchObject({
      data: Buffer.from("large"),
      coverSize: "700",
    });
  });

  it("releases a failed cover download so the next request can retry", async () => {
    mocks.downloadBinary
      .mockRejectedValueOnce(new Error("network failed"))
      .mockResolvedValueOnce({
        data: Buffer.from("retry"),
        contentType: "image/png",
      });
    const service = new DesktopNativeDataService(
      { downloadBinary: mocks.downloadBinary } as never,
      () => {},
    );

    await expect(
      service.downloadCoverImage({ coverArtId: "retry-cover", size: "300" }),
    ).rejects.toThrow("network failed");
    await expect(
      service.downloadCoverImage({ coverArtId: "retry-cover", size: "300" }),
    ).resolves.toMatchObject({ file: { coverSize: "300" } });

    expect(mocks.downloadBinary).toHaveBeenCalledTimes(2);
  });

  it("downloads covers when native sync receives cover options", async () => {
    mocks.request.mockImplementation(async ({ path }: { path: string }) => {
      if (path.includes("getGenres"))
        return response({ genres: { genre: [] } });
      if (path.includes("getPlaylists"))
        return response({ playlists: { playlist: [] } });
      if (path.includes("getStarred"))
        return response({ starred2: { song: [] } });
      if (path.includes("getArtists"))
        return response({
          artists: { index: [{ artist: [{ id: "ar1", name: "Artist" }] }] },
        });
      if (path.includes("getAlbumList"))
        return response({ albumList2: { album: [] } });
      throw new Error(`Unexpected request: ${path}`);
    });
    mocks.downloadBinary.mockResolvedValue({
      data: Buffer.from("cover"),
      contentType: "image/jpeg",
    });

    const service = new DesktopNativeDataService(
      {
        request: mocks.request,
        downloadBinary: mocks.downloadBinary,
        getCredentials: () => ({ serverType: "navidrome" }),
      } as never,
      () => {},
    );

    await service.syncAll({
      includeCoverArt: true,
      includeFullSongs: false,
      coverArtConcurrency: 2,
    });

    expect(mocks.downloadBinary).toHaveBeenCalledWith("/getCoverArt.view", {
      id: "ar1",
      size: "700",
    });
    expect(service.getSyncState()).toMatchObject({
      phase: "done",
      progress: 1,
    });
  });
});
