import {
  type UseQueryOptions,
  useInfiniteQuery,
  useQuery,
} from "@tanstack/react-query";
import { AonsokuNativeData, isNativeDataAvailable } from "@/native/data/facade";
import { useIsOnline } from "@/store/cache.store";
import { libraryDb } from "@/store/library-db";
import type { Albums, SingleAlbum } from "@/types/responses/album";
import type { IArtist } from "@/types/responses/artist";
import type { PlaylistWithEntries } from "@/types/responses/playlist";
import type { Search } from "@/types/responses/search";
import type { ISong } from "@/types/responses/song";
import {
  AlbumsFilters,
  SongsOrderByOptions,
  SortOptions,
  YearSortOptions,
} from "@/utils/albumsFilter";
import { matchesAllTokens, tokenizeQuery } from "@/utils/search";

/**
 * Readers that return the current IDB contents for each library table.
 * These always read Dexie regardless of network state — the sync service
 * is responsible for keeping Dexie fresh.
 */
export const offlineData = {
  genres: async () =>
    isNativeDataAvailable()
      ? (await AonsokuNativeData.getGenres()).items
      : libraryDb.genres.toArray(),
  artists: async () =>
    isNativeDataAvailable()
      ? (await AonsokuNativeData.getArtists({ limit: 100_000, offset: 0 }))
          .items
      : libraryDb.artists.toArray(),
  albums: async () =>
    isNativeDataAvailable()
      ? (await AonsokuNativeData.getAlbums({ limit: 100_000, offset: 0 })).items
      : libraryDb.albums.toArray(),
  songs: async () =>
    isNativeDataAvailable()
      ? (await AonsokuNativeData.getSongs({ limit: 100_000, offset: 0 })).items
      : libraryDb.songs.toArray(),
  playlists: async () =>
    isNativeDataAvailable()
      ? (await AonsokuNativeData.getPlaylists({ limit: 100_000, offset: 0 }))
          .items
      : libraryDb.playlists.toArray(),
} as const;

interface OfflineSearchOptions {
  query: string;
  artistCount?: number;
  albumCount?: number;
  songCount?: number;
}

export async function getOfflineSearchResults(
  options: OfflineSearchOptions,
): Promise<Search> {
  const { query, artistCount = 20, albumCount = 20, songCount = 20 } = options;
  const tokens = tokenizeQuery(query);

  if (tokens.length === 0) {
    return { artist: [], album: [], song: [] };
  }

  const [artists, albums, songs] = await Promise.all([
    offlineData.artists(),
    offlineData.albums(),
    offlineData.songs(),
  ]);

  const matchedArtists = artists
    .filter((artist) => matchesAllTokens(tokens, [artist.name]))
    .slice(0, artistCount);

  const matchedAlbums = albums
    .filter((album) =>
      matchesAllTokens(tokens, [album.name, album.artist, album.genre]),
    )
    .slice(0, albumCount);

  const matchedSongs = songs
    .filter((song) =>
      matchesAllTokens(tokens, [song.title, song.artist, song.album]),
    )
    .slice(0, songCount);

  return {
    artist: matchedArtists.length > 0 ? matchedArtists : undefined,
    album: matchedAlbums.length > 0 ? matchedAlbums : undefined,
    song: matchedSongs.length > 0 ? matchedSongs : undefined,
  };
}

function normalizeArtistAlbums(
  albums: Albums[],
  artistName: string,
  artistId: string,
): Albums[] {
  return albums.map((album) => ({
    ...album,
    artist: album.artist || artistName,
    artistId: album.artistId || artistId,
  }));
}

function compareAlbumCreatedDesc(a: Albums, b: Albums): number {
  const aTime = a.created ? Date.parse(a.created) || 0 : 0;
  const bTime = b.created ? Date.parse(b.created) || 0 : 0;
  return bTime - aTime;
}

function compareAlbumPlayedDesc(a: Albums, b: Albums): number {
  const aTime = a.played ? Date.parse(a.played) || 0 : 0;
  const bTime = b.played ? Date.parse(b.played) || 0 : 0;
  return bTime - aTime;
}

function sortAlbumsByName(albums: Albums[]): Albums[] {
  return [...albums].sort((a, b) => a.name.localeCompare(b.name));
}

function sortAlbumsByArtist(albums: Albums[]): Albums[] {
  return [...albums].sort((a, b) => {
    const byArtist = (a.artist || "").localeCompare(b.artist || "");
    if (byArtist !== 0) return byArtist;
    return a.name.localeCompare(b.name);
  });
}

function sortAlbumsByYear(
  albums: Albums[],
  yearFilter: `${YearSortOptions}`,
): Albums[] {
  return [...albums].sort((a, b) => {
    const yearA = a.year ?? 0;
    const yearB = b.year ?? 0;
    const comparison = yearA - yearB;
    if (comparison !== 0) {
      return yearFilter === YearSortOptions.Oldest ? comparison : -comparison;
    }
    return a.name.localeCompare(b.name);
  });
}

function sortSongs(
  songs: ISong[],
  orderBy: SongsOrderByOptions,
  sort: SortOptions,
): ISong[] {
  const isAsc = sort === SortOptions.Asc;

  return [...songs].sort((a, b) => {
    let comparison = 0;

    switch (orderBy) {
      case SongsOrderByOptions.Artist:
        comparison = (a.artist || "").localeCompare(b.artist || "");
        break;
      case SongsOrderByOptions.Title:
        comparison = (a.title || "").localeCompare(b.title || "");
        break;
      case SongsOrderByOptions.Album:
        comparison = (a.album || "").localeCompare(b.album || "");
        break;
      case SongsOrderByOptions.LastAdded:
      default: {
        const dateA = a.created ? new Date(a.created).getTime() || 0 : 0;
        const dateB = b.created ? new Date(b.created).getTime() || 0 : 0;
        comparison = dateA - dateB;
      }
    }

    return isAsc ? comparison : -comparison;
  });
}

function buildAlbumSkeleton(song: ISong): Albums {
  return {
    id: song.albumId,
    name: song.album,
    artist: song.artist,
    artistId: song.artistId,
    coverArt: song.coverArt,
    songCount: 0,
    duration: 0,
    playCount: 0,
    created: song.created,
    starred: undefined,
    year: song.year,
    genre: song.genre ?? "",
    played: song.played,
    userRating: 0,
    genres: [],
    musicBrainzId: "",
    isCompilation: false,
    sortName: song.album,
    discTitles: [],
    artists: song.albumArtists ?? song.artists,
    displayArtist: song.displayAlbumArtist ?? song.displayArtist,
    explicitStatus: song.explicitStatus,
    version: undefined,
  };
}

function accumulateAlbumFromSongs(existing: Albums, song: ISong): Albums {
  const createdTime = existing.created ? Date.parse(existing.created) || 0 : 0;
  const songCreatedTime = song.created ? Date.parse(song.created) || 0 : 0;
  const playedTime = existing.played ? Date.parse(existing.played) || 0 : 0;
  const songPlayedTime = song.played ? Date.parse(song.played) || 0 : 0;

  return {
    ...existing,
    artist: existing.artist || song.artist,
    artistId: existing.artistId || song.artistId,
    coverArt: existing.coverArt || song.coverArt,
    songCount: existing.songCount + 1,
    duration: existing.duration + song.duration,
    playCount: (existing.playCount ?? 0) + (song.playCount ?? 0),
    created:
      songCreatedTime > createdTime && song.created
        ? song.created
        : existing.created,
    starred: existing.starred ?? song.starred,
    year: existing.year || song.year,
    genre: existing.genre || song.genre || "",
    played:
      songPlayedTime > playedTime && song.played
        ? song.played
        : existing.played,
    artists:
      existing.artists && existing.artists.length > 0
        ? existing.artists
        : (song.albumArtists ?? song.artists),
    displayArtist:
      existing.displayArtist || song.displayAlbumArtist || song.displayArtist,
    explicitStatus: existing.explicitStatus || song.explicitStatus,
  };
}

function buildAlbumsFromSongs(songs: ISong[]): Albums[] {
  const byAlbum = new Map<string, Albums>();

  for (const song of songs) {
    if (!song.albumId) continue;
    const existing = byAlbum.get(song.albumId);
    if (!existing) {
      byAlbum.set(
        song.albumId,
        accumulateAlbumFromSongs(buildAlbumSkeleton(song), song),
      );
      continue;
    }
    byAlbum.set(song.albumId, accumulateAlbumFromSongs(existing, song));
  }

  return Array.from(byAlbum.values());
}

function withAlbumSongDefaults(song: ISong): ISong {
  return {
    ...song,
    genres: song.genres ?? [],
    replayGain: song.replayGain ?? {
      trackGain: 0,
      trackPeak: 0,
      albumGain: 0,
      albumPeak: 0,
    },
    albumArtists: song.albumArtists ?? song.artists,
  };
}

export async function getOfflineAlbumDetail(
  albumId: string,
): Promise<SingleAlbum> {
  const [album, songs] = await Promise.all([
    libraryDb.albums.get(albumId),
    libraryDb.songs.where("albumId").equals(albumId).toArray(),
  ]);

  if (!album) {
    throw new Error(`Album ${albumId} not found offline`);
  }

  const songsUnavailable = songs.length === 0 && album.songCount > 0;

  return {
    ...album,
    songsUnavailable: songsUnavailable || undefined,
    song: songs.map(withAlbumSongDefaults).sort((a, b) => {
      if ((a.discNumber ?? 0) !== (b.discNumber ?? 0)) {
        return (a.discNumber ?? 0) - (b.discNumber ?? 0);
      }
      return (a.track ?? 0) - (b.track ?? 0);
    }),
    recordLabels: album.recordLabels ?? [],
    discTitles: album.discTitles ?? [],
    genres: album.genres ?? [],
    moods: album.moods ?? [],
    releaseTypes: album.releaseTypes ?? [],
  };
}

export async function getOfflineArtistDetail(
  artistId: string,
): Promise<IArtist> {
  const [artist, albums] = await Promise.all([
    libraryDb.artists.get(artistId),
    libraryDb.albums.where("artistId").equals(artistId).toArray(),
  ]);

  if (!artist) {
    throw new Error(`Artist ${artistId} not found offline`);
  }

  return {
    ...artist,
    album: normalizeArtistAlbums(
      sortAlbumsByYear(albums, YearSortOptions.Newest),
      artist.name,
      artist.id,
    ),
  };
}

export async function getOfflinePlaylistDetail(
  playlistId: string,
): Promise<PlaylistWithEntries> {
  const playlist = await libraryDb.playlistDetails.get(playlistId);

  if (!playlist) {
    throw new Error(`Playlist ${playlistId} not found offline`);
  }

  return {
    ...playlist,
    entry: playlist.entry ?? [],
  };
}

export async function getOfflineAlbumsList(params: {
  currentFilter: string;
  yearFilter: `${YearSortOptions}`;
  genre: string;
  artistId: string;
  query: string;
}): Promise<Albums[]> {
  const { currentFilter, yearFilter, genre, artistId, query } = params;

  if (artistId) {
    const artist = await getOfflineArtistDetail(artistId);
    return artist.album ?? [];
  }

  let albums = await offlineData.albums();
  if (albums.length === 0) {
    const songs = await offlineData.songs();
    albums = buildAlbumsFromSongs(songs);
  }

  switch (currentFilter) {
    case AlbumsFilters.ByArtist:
      return sortAlbumsByArtist(albums);
    case AlbumsFilters.ByGenre:
      return sortAlbumsByName(albums.filter((album) => album.genre === genre));
    case AlbumsFilters.Starred:
      return [...albums]
        .filter((album) => Boolean(album.starred))
        .sort((a, b) => {
          const aTime = a.starred ? Date.parse(a.starred) || 0 : 0;
          const bTime = b.starred ? Date.parse(b.starred) || 0 : 0;
          return bTime - aTime;
        });
    case AlbumsFilters.MostPlayed:
      return [...albums].sort(
        (a, b) => (b.playCount ?? 0) - (a.playCount ?? 0),
      );
    case AlbumsFilters.ByName:
      return sortAlbumsByName(albums);
    case AlbumsFilters.Random:
      return [...albums]
        .map((album) => ({ album, key: Math.random() }))
        .sort((a, b) => a.key - b.key)
        .map(({ album }) => album);
    case AlbumsFilters.RecentlyPlayed:
      return [...albums]
        .filter((album) => Boolean(album.played))
        .sort(compareAlbumPlayedDesc);
    case AlbumsFilters.ByYear:
      return sortAlbumsByYear(albums, yearFilter);
    case AlbumsFilters.Search: {
      const trimmed = query.trim().toLocaleLowerCase();
      if (!trimmed) return [];
      return sortAlbumsByName(
        albums.filter((album) =>
          [album.name, album.artist, album.genre]
            .filter(Boolean)
            .some((value) => value!.toLocaleLowerCase().includes(trimmed)),
        ),
      );
    }
    case AlbumsFilters.RecentlyAdded:
    default:
      return [...albums].sort(compareAlbumCreatedDesc);
  }
}

export async function getOfflineSongsList(params: {
  filter: string;
  query: string;
  artistId: string;
  orderBy: SongsOrderByOptions;
  sort: SortOptions;
}): Promise<ISong[]> {
  const { filter, query, artistId, orderBy, sort } = params;
  const allSongs = await offlineData.songs();
  let songs = allSongs;

  if (artistId) {
    songs = songs.filter((song) => song.artistId === artistId);
  } else if (filter === AlbumsFilters.Search) {
    const trimmed = query.trim().toLocaleLowerCase();
    songs = trimmed
      ? songs.filter((song) =>
          [song.title, song.artist, song.album]
            .filter(Boolean)
            .some((value) => value!.toLocaleLowerCase().includes(trimmed)),
        )
      : songs;
  }

  return sortSongs(songs, orderBy, sort);
}

function isEmptyResult(v: unknown): boolean {
  if (v == null) return true;
  if (Array.isArray(v)) return v.length === 0;
  return false;
}

/**
 * Build a queryFn that reads IDB first and falls back to the network
 * only when IDB has nothing to offer (fresh install, never synced,
 * specific entity not yet in cache). Once IDB is populated, the network
 * path is never taken — the SyncService repopulates IDB in the
 * background and calls `queryClient.invalidateQueries` to refresh the UI.
 */
export function idbFirstQueryFn<T>(
  onlineFn: () => Promise<T>,
  offlineFn?: () => Promise<T>,
  options?: { acceptEmpty?: boolean },
): () => Promise<T> {
  if (!offlineFn) return onlineFn;
  return async () => {
    try {
      const cached = await offlineFn();
      if (options?.acceptEmpty ? cached != null : !isEmptyResult(cached)) {
        return cached;
      }
    } catch (err) {
      console.warn(
        "[offlineQueryClient] IDB read failed, falling back to network:",
        err,
      );
    }
    return onlineFn();
  };
}

// Legacy export name. Behavior is now IDB-first regardless of network
// state (previously branched on `isOfflineMode`). Kept for callers that
// still import the old name — will be removed once all callsites migrate
// to `idbFirstQueryFn` or `useOfflineQuery`.
export const offlineAwareQueryFn = idbFirstQueryFn;

type QueryOptionKeys<T> = Pick<
  UseQueryOptions<T>,
  | "staleTime"
  | "gcTime"
  | "refetchInterval"
  | "refetchOnWindowFocus"
  | "refetchOnMount"
  | "refetchOnReconnect"
  | "initialData"
  | "placeholderData"
>;

interface UseOfflineQueryOptions<T> extends QueryOptionKeys<T> {
  enabled?: boolean;
  offlineFn?: () => Promise<T>;
}

/**
 * React Query wrapper that prefers IDB over the network. When
 * `offlineFn` is provided, the IDB read is always attempted first;
 * the network fetch is only used when IDB is empty or the read throws.
 *
 * When `offlineFn` is not provided (pure-network queries like
 * getArtistInfo, getAlbumInfo), the hook disables the query while the
 * user is offline so the UI doesn't flash an error screen on startup.
 */
export function useOfflineQuery<T>(
  queryKey: unknown[],
  onlineFn: () => Promise<T>,
  options?: UseOfflineQueryOptions<T>,
) {
  const isOnline = useIsOnline();
  const { offlineFn, enabled, ...queryOptions } = options ?? {};

  // With an IDB fallback we can always run; otherwise require network.
  const canRun = offlineFn ? true : isOnline;
  const resolvedEnabled = enabled !== undefined ? enabled && canRun : canRun;

  return useQuery<T>({
    queryKey,
    queryFn: idbFirstQueryFn(onlineFn, offlineFn, {
      // When the user is offline we should surface an authoritative
      // empty cache result instead of attempting a guaranteed-failing
      // network fallback.
      acceptEmpty: !isOnline,
    }),
    enabled: resolvedEnabled,
    ...queryOptions,
  });
}

interface UseOfflineInfiniteQueryOptions<TPage> {
  enabled?: boolean;
  offlineFn?: () => Promise<TPage>;
  initialPageParam: number;
  getNextPageParam: (lastPage: TPage) => number | null | undefined;
}

export function useOfflineInfiniteQuery<TPage>(
  queryKey: unknown[],
  onlineFn: ({ pageParam }: { pageParam: number }) => Promise<TPage>,
  options: UseOfflineInfiniteQueryOptions<TPage>,
) {
  const isOnline = useIsOnline();
  const { offlineFn, enabled, initialPageParam, getNextPageParam } = options;

  const canRun = offlineFn ? true : isOnline;
  const resolvedEnabled = enabled !== undefined ? enabled && canRun : canRun;

  return useInfiniteQuery<TPage>({
    queryKey,
    queryFn: async ({ pageParam }) => {
      if (offlineFn && !isOnline) {
        return offlineFn();
      }

      return onlineFn({ pageParam });
    },
    enabled: resolvedEnabled,
    initialPageParam,
    getNextPageParam,
  });
}
