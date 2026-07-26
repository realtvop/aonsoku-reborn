import { getCoverArtUrl } from "@/api/httpClient";
// TODO: CachedImage provides lazy loading only — no application-level caching.
// Consider adding a CacheFirst strategy for /rest/getCoverArt in the service worker,
// or an in-memory LRU URL cache to avoid recomputing cover art URLs every render.
import { usePlayerStore } from "@/store/player/store";
import { CoverArt } from "@/types/coverArtType";
import { ISong } from "@/types/responses/song";

function resolveSongCoverArtId(
  song: Pick<ISong, "albumId" | "coverArt">,
  useAlbumCoverForSongs: boolean,
) {
  if (useAlbumCoverForSongs && song.albumId) {
    return song.albumId;
  }

  return song.coverArt;
}

export function getSongCoverArtId(song: Pick<ISong, "albumId" | "coverArt">) {
  const useAlbumCoverForSongs =
    usePlayerStore.getState().settings.coverArt.useAlbumCoverForSongs;

  return resolveSongCoverArtId(song, useAlbumCoverForSongs);
}

export function getSongCoverArtUrl(
  song: Pick<ISong, "albumId" | "coverArt">,
  size = "300",
) {
  return getCoverArtUrl(getSongCoverArtId(song), "song", size);
}

export function useSongCoverArtUrl(
  song: Pick<ISong, "albumId" | "coverArt">,
  size = "300",
) {
  const useAlbumCoverForSongs = usePlayerStore(
    (state) => state.settings.coverArt.useAlbumCoverForSongs,
  );

  return getCoverArtUrl(
    resolveSongCoverArtId(song, useAlbumCoverForSongs),
    "song",
    size,
  );
}

export function getCoverArtUrlFromSongPreference({
  coverArt,
  coverArtType,
  albumId,
  size = "300",
}: {
  coverArt?: string;
  coverArtType?: CoverArt;
  albumId?: string;
  size?: string;
}) {
  const id =
    coverArtType === "song" && albumId
      ? getSongCoverArtId({ albumId, coverArt: coverArt ?? "" })
      : coverArt;

  return getCoverArtUrl(id, coverArtType, size);
}

export function useCoverArtUrlFromSongPreference({
  coverArt,
  coverArtType,
  albumId,
  size = "300",
}: {
  coverArt?: string;
  coverArtType?: CoverArt;
  albumId?: string;
  size?: string;
}) {
  const useAlbumCoverForSongs = usePlayerStore(
    (state) => state.settings.coverArt.useAlbumCoverForSongs,
  );

  const id =
    coverArtType === "song" && albumId
      ? resolveSongCoverArtId(
          { albumId, coverArt: coverArt ?? "" },
          useAlbumCoverForSongs,
        )
      : coverArt;

  return getCoverArtUrl(id, coverArtType, size);
}

export function getDefaultArtUrl(_coverArtType?: CoverArt): undefined {
  return undefined;
}

export function resolveCacheKeys(
  coverArtId: string | undefined,
  coverArtType: CoverArt | undefined,
  albumId: string | undefined,
): string[] {
  if (coverArtType === "song" && albumId) {
    const useAlbumCoverForSongs =
      usePlayerStore.getState().settings.coverArt.useAlbumCoverForSongs;

    if (useAlbumCoverForSongs) {
      const alternateId =
        coverArtId && coverArtId !== albumId ? coverArtId : undefined;
      return alternateId ? [albumId, alternateId] : [albumId];
    }

    // When off, prefer song cover but always fallback to album cover
    const preferredId = coverArtId || albumId;
    const alternateId =
      coverArtId && coverArtId !== albumId ? albumId : undefined;
    return alternateId ? [preferredId, alternateId] : [preferredId];
  }
  if (!coverArtId) return [];
  return [coverArtId];
}
