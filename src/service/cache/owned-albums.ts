import type { LibraryDB } from "@/store/library-db";
import { withStarredAt } from "@/store/library-db";
import type { Albums } from "@/types/responses/album";

type AlbumSummary = Partial<Albums> & Pick<Albums, "id" | "name" | "artist">;

export function normalizeAlbum(album: AlbumSummary): Albums {
  return {
    ...album,
    coverArt: album.coverArt ?? "",
    songCount: album.songCount ?? 0,
    duration: album.duration ?? 0,
    created: album.created ?? "",
    genre: album.genre ?? "",
    userRating: album.userRating ?? 0,
    genres: album.genres ?? [],
    musicBrainzId: album.musicBrainzId ?? "",
    isCompilation: album.isCompilation ?? false,
    sortName: album.sortName ?? album.name,
    discTitles: album.discTitles ?? [],
  };
}

/** Album rows and their owner are committed together, including an empty library. */
export async function replaceOwnedAlbums(
  db: LibraryDB,
  albums: AlbumSummary[],
  owner: string,
  signal: AbortSignal,
) {
  signal.throwIfAborted();
  await db.transaction("rw", db.albums, async () => {
    await db.albums.clear();
    for (let offset = 0; offset < albums.length; offset += 2000) {
      signal.throwIfAborted();
      await db.albums.bulkPut(
        albums.slice(offset, offset + 2000).map((album) => ({
          ...withStarredAt(normalizeAlbum(album)),
          libraryOwner: owner,
        })),
      );
    }
    signal.throwIfAborted();
  });
}

/** Reservoir sampling scans metadata while retaining only the requested candidates. */
export async function sampleOwnedAlbums(
  db: LibraryDB,
  owner: string,
  size: number,
  random = Math.random,
): Promise<Albums[]> {
  const sample: Albums[] = [];
  let seen = 0;
  await db.albums.each((row) => {
    if (row.libraryOwner !== owner || size <= 0) return;
    seen += 1;
    const index =
      sample.length < size ? sample.length : Math.floor(random() * seen);
    if (index < size) {
      const { libraryOwner: _owner, ...album } = row;
      sample[index] = normalizeAlbum(album);
    }
  });
  for (let i = sample.length - 1; i > 0; i -= 1) {
    const j = Math.floor(random() * (i + 1));
    [sample[i], sample[j]] = [sample[j], sample[i]];
  }
  return sample;
}
