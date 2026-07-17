export interface DesktopArtworkUrlResolvers {
  isLinux: boolean;
  resolveCachedFile: (coverArtId: string) => string | undefined;
  resolveAuthenticatedUrl: (
    coverArtId: string,
    params: Record<string, string>,
  ) => string;
}

function parseCoverReference(
  artworkUrl: string,
): { coverArtId: string; params: Record<string, string> } | null {
  if (artworkUrl.startsWith("aonsoku-media://")) {
    const parsed = new URL(artworkUrl);
    const operation = parsed.hostname || parsed.pathname.replace(/^\//, "");
    if (operation !== "getCoverArt") return null;
    const coverArtId = parsed.searchParams.get("id");
    if (!coverArtId) return null;
    return {
      coverArtId,
      params: Object.fromEntries(parsed.searchParams),
    };
  }

  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(artworkUrl)) {
    return { coverArtId: artworkUrl, params: { id: artworkUrl, size: "300" } };
  }

  return null;
}

export function resolveDesktopSystemArtworkUrl(
  artworkUrl: string | undefined,
  resolvers: DesktopArtworkUrlResolvers,
): string | undefined {
  if (!artworkUrl) return undefined;

  try {
    const reference = parseCoverReference(artworkUrl);
    if (artworkUrl.startsWith("aonsoku-media://") && !reference) {
      return undefined;
    }
    if (resolvers.isLinux) {
      // MPRIS metadata is visible to every process on the user's session bus.
      // Publish only a local cache URI that contains no replayable server
      // credentials. If the cover is not cached yet, omit it.
      if (!reference) return undefined;
      const cached = resolvers.resolveCachedFile(reference.coverArtId);
      return cached?.startsWith("file://") ? cached : undefined;
    }

    if (!reference) return artworkUrl;
    return resolvers.resolveAuthenticatedUrl(
      reference.coverArtId,
      reference.params,
    );
  } catch {
    return undefined;
  }
}
