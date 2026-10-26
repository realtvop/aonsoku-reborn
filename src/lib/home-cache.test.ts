import { describe, expect, it, vi } from "vitest";
import {
  HOME_RANDOM_CACHE_MAX_AGE,
  type HomeCacheEntry,
  loadCachedHomeData,
} from "./home-cache";

describe("Home random selection persistence", () => {
  function fixture(initial?: HomeCacheEntry<string[]> | string[]) {
    let stored = initial;
    let clock = 1_800_000_000_000;
    const fresh = vi.fn(async () => ["server-new"]);
    const write = vi.fn(async (entry: HomeCacheEntry<string[]>) => {
      stored = entry;
    });
    const publish = vi.fn();
    const load = (
      options: { force?: boolean; online?: boolean; keepRandom?: boolean } = {},
    ) =>
      loadCachedHomeData<string[]>({
        read: async () => stored,
        write,
        local: async () => ["local-seed"],
        fresh,
        publish,
        hasContent: (value) => value.length > 0,
        now: () => clock,
        signal: new AbortController().signal,
        keepRandom: true,
        online: true,
        ...options,
      });
    return {
      load,
      fresh,
      write,
      publish,
      advance: (ms: number) => {
        clock += ms;
      },
    };
  }

  it("keeps the startup selection through repeated automatic refreshes without extending its lifetime", async () => {
    const f = fixture({
      version: 2,
      savedAt: 1_800_000_000_000,
      value: ["cached"],
    });
    f.advance(HOME_RANDOM_CACHE_MAX_AGE / 2);
    expect(await f.load()).toEqual(["cached"]);
    expect(await f.load()).toEqual(["cached"]);
    expect(f.fresh).not.toHaveBeenCalled();
    expect(f.write).not.toHaveBeenCalled();
    f.advance(HOME_RANDOM_CACHE_MAX_AGE / 2);
    expect(await f.load()).toEqual(["server-new"]);
    expect(f.fresh).toHaveBeenCalledTimes(1);
  });

  it("migrates old untimed snapshots without rerolling them on the first startup", async () => {
    const f = fixture(["legacy"]);
    expect(await f.load()).toEqual(["legacy"]);
    expect(f.write).toHaveBeenCalledTimes(1);
    expect(f.fresh).not.toHaveBeenCalled();
    f.advance(HOME_RANDOM_CACHE_MAX_AGE);
    expect(await f.load()).toEqual(["server-new"]);
  });

  it("persists the first local selection even offline so the next load keeps its order", async () => {
    const f = fixture();
    expect(await f.load({ online: false })).toEqual(["local-seed"]);
    expect(f.write).toHaveBeenCalledTimes(1);
    expect(await f.load()).toEqual(["local-seed"]);
    expect(f.fresh).not.toHaveBeenCalled();
  });

  it("forces manual random refresh and retains the cached selection when the server fails", async () => {
    const f = fixture(["cached"]);
    f.fresh.mockRejectedValueOnce(new Error("offline"));
    expect(await f.load({ force: true })).toEqual(["cached"]);
    expect(await f.load({ force: true })).toEqual(["server-new"]);
    expect(f.fresh).toHaveBeenCalledTimes(2);
  });

  it("refreshes dynamic sections normally and preserves even an empty successful cache on failure", async () => {
    const f = fixture({ version: 2, savedAt: 1_800_000_000_000, value: [] });
    f.fresh.mockRejectedValueOnce(new Error("offline"));
    expect(await f.load({ keepRandom: false })).toEqual([]);
    expect(await f.load({ keepRandom: false })).toEqual(["server-new"]);
    expect(f.fresh).toHaveBeenCalledTimes(2);
  });
});
