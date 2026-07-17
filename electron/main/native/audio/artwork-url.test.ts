import { describe, expect, it, vi } from "vitest";
import { resolveDesktopSystemArtworkUrl } from "./artwork-url";

function resolvers(isLinux: boolean) {
  return {
    isLinux,
    resolveCachedFile: vi.fn((id: string) =>
      id === "cached-cover"
        ? "file:///home/user/.config/Aonsoku/CoverCache/cached-cover.jpg"
        : undefined,
    ),
    resolveAuthenticatedUrl: vi.fn(
      (_id: string, params: Record<string, string>) =>
        `https://server/getCoverArt.view?id=${params.id}&u=user&t=secret`,
    ),
  };
}

describe("resolveDesktopSystemArtworkUrl", () => {
  it("publishes only cached file URIs on Linux", () => {
    const options = resolvers(true);

    expect(resolveDesktopSystemArtworkUrl("cached-cover", options)).toBe(
      "file:///home/user/.config/Aonsoku/CoverCache/cached-cover.jpg",
    );
    expect(
      resolveDesktopSystemArtworkUrl("missing-cover", options),
    ).toBeUndefined();
    expect(
      resolveDesktopSystemArtworkUrl(
        "https://server/getCoverArt.view?id=cover&u=user&t=secret",
        options,
      ),
    ).toBeUndefined();
    expect(options.resolveAuthenticatedUrl).not.toHaveBeenCalled();
  });

  it("rejects non-file values returned by the Linux cache resolver", () => {
    const options = resolvers(true);
    options.resolveCachedFile.mockReturnValue(
      "https://server/getCoverArt.view?u=user&t=secret",
    );

    expect(resolveDesktopSystemArtworkUrl("cover", options)).toBeUndefined();
  });

  it("keeps authenticated platform artwork resolution off Linux", () => {
    const options = resolvers(false);

    expect(
      resolveDesktopSystemArtworkUrl(
        "aonsoku-media://getCoverArt?id=cover-1&size=300",
        options,
      ),
    ).toBe("https://server/getCoverArt.view?id=cover-1&u=user&t=secret");
    expect(
      resolveDesktopSystemArtworkUrl(
        "aonsoku-media://unsupported?id=cover-1",
        options,
      ),
    ).toBeUndefined();
  });
});
