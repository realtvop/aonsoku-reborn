import { useQuery } from "@tanstack/react-query";
import { useCachedHomeQuery } from "@/app/hooks/use-home-cache";
import { subsonic } from "@/service/subsonic";
import { useIsOnline } from "@/store/cache.store";
import { usePinnedHomeItems } from "@/store/pinned-home.store";
import {
  type AlbumListType,
  type Albums,
  type AlbumsListData,
  type SingleAlbum,
} from "@/types/responses/album";
import {
  type Playlist,
  type PlaylistWithEntries,
} from "@/types/responses/playlist";
import { type PinnedHomeItem } from "@/types/pinnedHome";
import { convertMinutesToMs } from "@/utils/convertSecondsToTime";
import { queryKeys } from "@/utils/queryKeys";

const HOME_SECTION_SIZE = 16;
type HomeAlbumListType = Extract<
  AlbumListType,
  "frequent" | "newest" | "random" | "recent"
>;

export interface HomePinnedAlbumItem {
  type: "album";
  album: Albums;
  playedAt: number;
}

export interface HomePinnedPlaylistItem {
  type: "playlist";
  playlist: Playlist;
  detail?: PlaylistWithEntries;
  playedAt: number;
}

export type HomePinnedItemData = HomePinnedAlbumItem | HomePinnedPlaylistItem;

function toTimestamp(value?: string) {
  if (!value) return 0;

  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function toAlbumSummary(album: SingleAlbum): Albums {
  const { song: _song, ...summary } = album;
  return summary;
}

function buildAlbumsListData(list: Albums[]): AlbumsListData {
  return {
    list,
    albumsCount: list.length,
  };
}

export function getPlaylistPlayedAt(
  playlist: Pick<Playlist, "changed" | "created">,
  detail?: Pick<PlaylistWithEntries, "entry">,
) {
  const mostRecentEntryPlayedAt =
    detail?.entry.reduce((latest, song) => {
      return Math.max(latest, toTimestamp(song.played));
    }, 0) ?? 0;

  return (
    mostRecentEntryPlayedAt ||
    toTimestamp(playlist.changed) ||
    toTimestamp(playlist.created)
  );
}

export function sortPinnedHomeItemsByPlayedAt(items: HomePinnedItemData[]) {
  return [...items].sort((left, right) => {
    if (right.playedAt !== left.playedAt) {
      return right.playedAt - left.playedAt;
    }

    const leftName =
      left.type === "album" ? left.album.name : left.playlist.name;
    const rightName =
      right.type === "album" ? right.album.name : right.playlist.name;

    return leftName.localeCompare(rightName);
  });
}

/** Network refreshes must not resolve pins from another account's global IDB. */
export async function getPinnedHomeItems(
  items: PinnedHomeItem[],
  isOnline: boolean,
): Promise<HomePinnedItemData[]> {
  if (!isOnline || items.length === 0) return [];
  const values = await Promise.all(
    items.map(async (item): Promise<HomePinnedItemData | null> => {
      if (item.type === "album") {
        const detail = await subsonic.albums.getOne(item.id);
        if (!detail) return null;
        const playedAt = (detail.song ?? []).reduce(
          (latest, song) => Math.max(latest, toTimestamp(song.played)),
          toTimestamp(detail.played),
        );
        return { type: "album", album: toAlbumSummary(detail), playedAt };
      }
      const detail = await subsonic.playlists.getOne(item.id);
      if (!detail) return null;
      const { entry: _entry, ...playlist } = detail;
      return {
        type: "playlist",
        playlist,
        detail,
        playedAt: getPlaylistPlayedAt(playlist, detail),
      };
    }),
  );
  return sortPinnedHomeItemsByPlayedAt(
    values.filter((value): value is HomePinnedItemData => value !== null),
  );
}

function useHomeAlbumQuery(
  queryKey: readonly unknown[],
  type: HomeAlbumListType,
  options?: { refetchInterval?: number | false },
) {
  const isOnline = useIsOnline();

  return useCachedHomeQuery<AlbumsListData>({
    key: queryKey,
    isOnline,
    keepRandom: type === "random",
    local: async () => buildAlbumsListData([]),
    fresh: () =>
      subsonic.albums.getAlbumList({ size: HOME_SECTION_SIZE, type }),
    hasContent: (value) => value.list.length > 0,
    ...options,
  });
}

export const useGetRandomSongs = () => {
  const isOnline = useIsOnline();

  return useQuery({
    queryKey: [...queryKeys.song.random],
    queryFn: () => subsonic.songs.getRandomSongs({ size: 10 }),
    enabled: isOnline,
  });
};

export const useGetRecentlyAdded = () =>
  useHomeAlbumQuery([...queryKeys.album.recentlyAdded], "newest");

export const useGetMostPlayed = () =>
  useHomeAlbumQuery([...queryKeys.album.mostPlayed], "frequent");

export const useGetRecentlyPlayed = () => {
  const isOnline = useIsOnline();

  return useHomeAlbumQuery([...queryKeys.album.recentlyPlayed], "recent", {
    refetchInterval: isOnline ? convertMinutesToMs(2) : false,
  });
};

export const useGetRandomAlbums = () =>
  useHomeAlbumQuery([...queryKeys.album.random], "random");

export const useGetCarouselAlbums = () => {
  const isOnline = useIsOnline();

  return useCachedHomeQuery<AlbumsListData>({
    key: ["albums", "carousel"],
    isOnline,
    keepRandom: true,
    local: async () => buildAlbumsListData([]),
    fresh: () => subsonic.albums.getAlbumList({ size: 10, type: "random" }),
    hasContent: (value) => value.list.length > 0,
  });
};

export const useGetPinnedHomeItems = () => {
  const isOnline = useIsOnline();
  const pinnedItems = usePinnedHomeItems();

  return useCachedHomeQuery<HomePinnedItemData[]>({
    key: [
      "home",
      "pinned",
      pinnedItems.map((item) => `${item.type}:${item.id}`).join("|"),
    ],
    isOnline,
    local: async () => [],
    fresh: () => getPinnedHomeItems(pinnedItems, true),
    hasContent: (value) => value.length > 0,
    enabled: pinnedItems.length > 0,
  });
};
