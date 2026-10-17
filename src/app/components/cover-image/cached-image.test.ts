import { beforeEach, expect, it, vi } from "vitest";

const { getCachedCoverUrlMock } = vi.hoisted(() => ({
  getCachedCoverUrlMock: vi.fn(),
}));

vi.mock("@/service/cache", () => ({
  cacheManager: {
    getCachedCoverUrl: getCachedCoverUrlMock,
  },
}));

import { selectCachedCoverUrl } from "./cached-image";

beforeEach(() => {
  getCachedCoverUrlMock.mockReset();
});

it("prefers a sufficient candidate before an offline smaller fallback", async () => {
  getCachedCoverUrlMock.mockImplementation(
    async (
      key: string,
      _size: string,
      options: { allowLowerResolution?: boolean },
    ) => {
      if (!options.allowLowerResolution && key === "large") return "large-url";
      if (options.allowLowerResolution) return `${key}-fallback-url`;
      return null;
    },
  );

  await expect(
    selectCachedCoverUrl(["small", "large"], "700", true),
  ).resolves.toBe("large-url");
  expect(getCachedCoverUrlMock).toHaveBeenCalledTimes(2);
  expect(getCachedCoverUrlMock).not.toHaveBeenCalledWith(
    expect.anything(),
    expect.anything(),
    { allowLowerResolution: true },
  );

  getCachedCoverUrlMock.mockReset();
  getCachedCoverUrlMock.mockImplementation(
    async (
      key: string,
      _size: string,
      options: { allowLowerResolution?: boolean },
    ) => {
      return options.allowLowerResolution ? `${key}-fallback-url` : null;
    },
  );

  await expect(
    selectCachedCoverUrl(["small", "other"], "700", true),
  ).resolves.toBe("small-fallback-url");
  expect(getCachedCoverUrlMock).toHaveBeenNthCalledWith(3, "small", "700", {
    allowLowerResolution: true,
  });
});
