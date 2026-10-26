import { useQuery } from "@tanstack/react-query";
import { useCachedHomeQuery } from "@/app/hooks/use-home-cache";
import {
  getOfflinePlaylistDetail,
  offlineData,
} from "@/lib/offlineQueryClient";
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

interface AlbumPlayStats {
  playedAt: number;
  playCount: number;
}

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

function shuffleAlbums(list: Albums[]) {
  const shuffled = [...list];

  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const randomIndex = Math.floor(Math.random() * (index + 1));

    [shuffled[index], shuffled[randomIndex]] = [
      shuffled[randomIndex],
      shuffled[index],
    ];
  }

  return shuffled;
}

function getAlbumStatsById(
  songs: Awaited<ReturnType<(typeof offlineData)["songs"]>>,
) {
  const statsByAlbumId = new Map<string, AlbumPlayStats>();

  for (const song of songs) {
    if (!song.albumId) continue;

    const stats = statsByAlbumId.get(song.albumId) ?? {
      playedAt: 0,
      playCount: 0,
    };

    stats.playCount += song.playCount ?? 0;
    stats.playedAt = Math.max(stats.playedAt, toTimestamp(song.played));
    statsByAlbumId.set(song.albumId, stats);
  }

  return statsByAlbumId;
}

function getAlbumPlayCount(
  album: Albums,
  statsByAlbumId: Map<string, AlbumPlayStats>,
) {
  return statsByAlbumId.get(album.id)?.playCount ?? album.playCount ?? 0;
}

function getAlbumPlayedAt(
  album: Albums,
  statsByAlbumId: Map<string, AlbumPlayStats>,
) {
  return statsByAlbumId.get(album.id)?.playedAt ?? toTimestamp(album.played);
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

async function getPinnedPlaylistDetail(playlistId: string, isOnline: boolean) {
  if (isOnline) {
    try {
      return await subsonic.playlists.getOne(playlistId);
    } catch (error) {
      console.warn(
        `[home] Failed to load pinned playlist ${playlistId}, falling back to IDB:`,
        error,
      );
    }
  }

  try {
    return await getOfflinePlaylistDetail(playlistId);
  } catch {
    return null;
  }
}

export async function getPinnedHomeItems(
  items: PinnedHomeItem[],
  isOnline: boolean,
): Promise<HomePinnedItemData[]> {
  if (items.length === 0) return [];

  const pinnedAlbumIds = items
    .filter((item) => item.type === "album")
    .map((item) => item.id);
  const shouldReadSongs = pinnedAlbumIds.length > 0;
  const [albums, playlists, songs] = await Promise.all([
    offlineData.albums(),
    offlineData.playlists(),
    shouldReadSongs ? offlineData.songs() : Promise.resolve([]),
  ]);

  const albumsById = new Map(albums.map((album) => [album.id, album]));
  const playlistsById = new Map(
    playlists.map((playlist) => [playlist.id, playlist]),
  );
  const albumStatsById = getAlbumStatsById(songs);

  const resolvedItems = await Promise.all(
    items.map(async (item): Promise<HomePinnedItemData | null> => {
      if (item.type === "album") {
        let album = albumsById.get(item.id);

        if (!album && isOnline) {
          try {
            const response = await subsonic.albums.getOne(item.id);
            album = response ? toAlbumSummary(response) : undefined;
          } catch (error) {
            console.warn(
              `[home] Failed to load pinned album ${item.id}:`,
              error,
            );
          }
        }

        if (!album) return null;

        return {
          type: "album",
          album,
          playedAt: getAlbumPlayedAt(album, albumStatsById),
        };
      }

      const playlist = playlistsById.get(item.id);
      const detail = await getPinnedPlaylistDetail(item.id, isOnline);

      if (!playlist && !detail) return null;

      const playlistSummary = playlist ?? detail;

      if (!playlistSummary) return null;

      return {
        type: "playlist",
        playlist: playlistSummary,
        detail: detail ?? undefined,
        playedAt: getPlaylistPlayedAt(playlistSummary, detail ?? undefined),
      };
    }),
  );

  return sortPinnedHomeItemsByPlayedAt(
    resolvedItems.filter((item): item is HomePinnedItemData => item !== null),
  );
}

async function getOfflineHomeAlbums(type: HomeAlbumListType) {
  const shouldReadSongStats = type === "frequent" || type === "recent";
  const [albums, songs] = await Promise.all([
    offlineData.albums(),
    shouldReadSongStats ? offlineData.songs() : Promise.resolve([]),
  ]);
  const sortedAlbums = [...albums];
  const statsByAlbumId = getAlbumStatsById(songs);

  if (type === "newest") {
    sortedAlbums.sort((albumA, albumB) => {
      return toTimestamp(albumB.created) - toTimestamp(albumA.created);
    });
  }

  if (type === "frequent") {
    sortedAlbums.sort((albumA, albumB) => {
      return (
        getAlbumPlayCount(albumB, statsByAlbumId) -
        getAlbumPlayCount(albumA, statsByAlbumId)
      );
    });
  }

  if (type === "recent") {
    sortedAlbums.sort((albumA, albumB) => {
      return (
        getAlbumPlayedAt(albumB, statsByAlbumId) -
        getAlbumPlayedAt(albumA, statsByAlbumId)
      );
    });
  }

  const visibleAlbums = sortedAlbums.filter((album) => {
    if (type === "frequent") {
      return getAlbumPlayCount(album, statsByAlbumId) > 0;
    }

    if (type === "recent") {
      return getAlbumPlayedAt(album, statsByAlbumId) > 0;
    }

    return true;
  });

  const list =
    type === "random"
      ? shuffleAlbums(visibleAlbums).slice(0, HOME_SECTION_SIZE)
      : visibleAlbums.slice(0, HOME_SECTION_SIZE);

  return buildAlbumsListData(list);
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
    local: () => getOfflineHomeAlbums(type),
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
    local: async () => {
      const result = await getOfflineHomeAlbums("random");
      return { ...result, list: result.list.slice(0, 10) };
    },
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
    local: () => getPinnedHomeItems(pinnedItems, false),
    fresh: () => getPinnedHomeItems(pinnedItems, true),
    hasContent: (value) => value.length > 0,
    enabled: pinnedItems.length > 0,
  });
};
