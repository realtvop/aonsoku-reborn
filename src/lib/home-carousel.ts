import { AonsokuNativeData, isNativeDataAvailable } from "@/native/data/facade";
import {
  normalizeAlbum,
  sampleOwnedAlbums,
} from "@/service/cache/owned-albums";
import { libraryDb } from "@/store/library-db";
import type { AlbumsListData } from "@/types/responses/album";

export async function localCarousel(
  owner: string,
  activeOwner: string,
  size = 10,
  fallbackOwner?: string,
): Promise<AlbumsListData> {
  if (isNativeDataAvailable()) {
    const page = await AonsokuNativeData.getAlbums({
      limit: size,
      offset: 0,
      sortBy: "random",
    });
    const list =
      page.libraryOwner !== undefined &&
      [owner, activeOwner, fallbackOwner].includes(page.libraryOwner)
        ? page.items.map((album) =>
            normalizeAlbum({ ...album, artist: album.artist ?? "" }),
          )
        : [];
    return { list, albumsCount: list.length };
  }
  const list = await sampleOwnedAlbums(libraryDb, owner, size);
  return { list, albumsCount: list.length };
}
