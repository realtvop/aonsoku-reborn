import { buildCoverArtUrl, type ServerAuthConfig } from "@/api/urlBuilder";
import {
  ensureAuth as workerEnsureAuth,
  workerHttpClient,
  initAuth as workerInitAuth,
  updateAuth as workerUpdateAuth,
} from "@/api/workerHttpClient";
import { coverKey } from "@/service/cache/cache-keys";
import { asyncPool } from "@/service/cache/concurrency";
import type { CacheMetaRow, PlaylistRow } from "@/store/library-db";
import { LibraryDB, withPlayedAt, withStarredAt } from "@/store/library-db";
import type { SyncPhase, SyncState, SyncTier } from "@/types/cache";
import type { AlbumListResponse } from "@/types/responses/album";
import type { ArtistsResponse, ISimilarArtist } from "@/types/responses/artist";
import type { GenresResponse } from "@/types/responses/genre";
import type {
  PlaylistsResponse,
  PlaylistWithEntries,
  PlaylistWithEntriesResponse,
} from "@/types/responses/playlist";
import type { ISearchResponse } from "@/types/responses/search";
import type { FavoritesResponse } from "@/types/responses/song";

export interface WorkerAuthConfig extends ServerAuthConfig {
  serverType?: string | null;
}

export interface SyncOptions {
  includeCoverArt?: boolean;
  includeFullSongs?: boolean;
  mode?: "full" | "incremental";
  songCount?: number;
  useAlbumCoverForSongs?: boolean;
  coverArtConcurrency?: number;
}

export interface Callbacks {
  onSyncStateUpdate(state: Partial<SyncState>): void;
  onInvalidateQueries(keys: string[][]): void;
  onLastSyncedAt(timestamp: number): void;
  onCacheIndexRefresh(): void;
}

export const TIER_FRESH_WINDOW_MS: Record<SyncTier, number> = {
  t1: 5 * 60 * 1000,
  t2: 30 * 60 * 1000,
  t3: 2 * 60 * 60 * 1000,
};

export const BULK_CHUNK_SIZE = 2000;
export const PLAYLIST_DETAIL_BATCH_SIZE = 25;

interface AlbumSummary {
  id: string;
  name: string;
  artist: string;
  artistId?: string;
  coverArt?: string;
  songCount: number;
  duration: number;
  year?: number;
  genre?: string;
  created: string;
  played?: string;
  playCount?: number;
  starred?: string;
}

const CACHE_NAME = "aonsoku-media-cache";

export async function getWorkerCache(): Promise<Cache> {
  return caches.open(CACHE_NAME);
}

export function wCacheKey(key: string): string {
  return `/_cache/${encodeURIComponent(key)}`;
}

export function wCacheKeyLegacy(key: string): string {
  return `/_cache/${key}`;
}

export async function cacheStoragePut(
  key: string,
  data: Blob,
  contentType: string,
): Promise<void> {
  const cache = await getWorkerCache();
  const response = new Response(data, {
    headers: {
      "Content-Type": contentType,
      "X-Cached-At": Date.now().toString(),
    },
  });
  await cache.put(wCacheKey(key), response);
}

export async function cacheStorageGet(key: string): Promise<Blob | null> {
  const cache = await getWorkerCache();
  let response = await cache.match(wCacheKey(key));
  if (!response) {
    response = await cache.match(wCacheKeyLegacy(key));
  }
  if (!response) return null;
  return response.blob();
}

export async function bulkPutInChunks<T, K>(
  table: { bulkPut: (rows: T[]) => Promise<K> },
  rows: T[],
  signal: AbortSignal,
): Promise<void> {
  for (let offset = 0; offset < rows.length; offset += BULK_CHUNK_SIZE) {
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
    await table.bulkPut(rows.slice(offset, offset + BULK_CHUNK_SIZE));
  }
}

interface ISong {
  id: string;
  parent: string;
  isDir: boolean;
  title: string;
  album: string;
  artist: string;
  track: number;
  year: number;
  coverArt: string;
  size: number;
  contentType: string;
  suffix: string;
  duration: number;
  bitRate: number;
  path: string;
  playCount?: number;
  discNumber: number;
  created: string;
  albumId: string;
  artistId?: string;
  type: string;
  isVideo: boolean;
  played?: string;
  starred?: string;
  bpm: number;
  comment: string;
  sortName: string;
  mediaType: string;
  musicBrainzId: string;
  genres: { name: string }[];
  replayGain: {
    trackGain: number;
    trackPeak: number;
    albumGain: number;
    albumPeak: number;
  };
  [k: string]: unknown;
}

export class SyncWorkerService {
  #abortController: AbortController | null = null;
  #syncGeneration = 0;
  #authReady: Promise<void>;
  #resolveAuthReady: () => void;

  #syncStateTimer: ReturnType<typeof setTimeout> | null = null;
  #pendingSyncState: Partial<SyncState> | null = null;

  #callbacks: Callbacks | null = null;

  db: LibraryDB;

  constructor(db?: LibraryDB) {
    this.db = db ?? new LibraryDB();
    this.#authReady = new Promise((resolve) => {
      this.#resolveAuthReady = resolve;
    });
  }

  initAuth(config: WorkerAuthConfig): void {
    workerInitAuth(config);
    this.#resolveAuthReady();
  }

  updateAuth(config: WorkerAuthConfig): void {
    workerUpdateAuth(config);
  }

  setCallbacks(callbacks: Callbacks): void {
    this.#callbacks = callbacks;
  }

  #flushSyncState(): void {
    if (this.#pendingSyncState) {
      const state = this.#pendingSyncState;
      this.#pendingSyncState = null;
      this.#callbacks?.onSyncStateUpdate(state);
    }
  }

  #updateSyncState(
    phase: SyncPhase,
    tier: SyncTier | undefined,
    processedItems = 0,
    totalItems = 0,
  ): void {
    this.#pendingSyncState = {
      phase,
      tier,
      isSyncing: phase !== "done" && phase !== "error" && phase !== "cancelled",
      processedItems,
      totalItems,
      progress:
        totalItems > 0 ? Math.round((processedItems / totalItems) * 100) : 0,
    };
    if (!this.#syncStateTimer) {
      this.#syncStateTimer = setTimeout(() => {
        this.#syncStateTimer = null;
        this.#flushSyncState();
      }, 200);
    }
  }

  #forceFlushSyncState(): void {
    if (this.#syncStateTimer) {
      clearTimeout(this.#syncStateTimer);
      this.#syncStateTimer = null;
    }
    this.#flushSyncState();
  }

  #checkAborted(signal: AbortSignal): void {
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  }

  async #recordTierCheckpoint(tier: SyncTier): Promise<void> {
    await this.db.syncState.put({
      key: `tier:${tier}`,
      lastSyncedAt: Date.now(),
    });
  }

  async #shouldSkipTier(
    tier: SyncTier,
    mode: "full" | "incremental",
  ): Promise<boolean> {
    if (mode === "full") return false;
    const entry = await this.db.syncState.get(`tier:${tier}`);
    if (!entry?.lastSyncedAt) return false;
    return Date.now() - entry.lastSyncedAt < TIER_FRESH_WINDOW_MS[tier];
  }

  async #syncPlaylistDetails(
    playlists: PlaylistRow[],
    signal: AbortSignal,
  ): Promise<void> {
    const playlistIds = new Set(playlists.map((p) => p.id));
    const existingIds = await this.db.playlistDetails
      .toCollection()
      .primaryKeys();
    const removedIds = existingIds.filter((id) => !playlistIds.has(id));

    if (
      removedIds.length > 0 &&
      playlists.length > 0 &&
      removedIds.length < existingIds.length
    ) {
      await this.db.playlistDetails.bulkDelete(removedIds);
    }

    for (
      let offset = 0;
      offset < playlists.length;
      offset += PLAYLIST_DETAIL_BATCH_SIZE
    ) {
      this.#checkAborted(signal);

      const batch = playlists.slice(
        offset,
        offset + PLAYLIST_DETAIL_BATCH_SIZE,
      );
      const results = await Promise.allSettled(
        batch.map((playlist) =>
          workerHttpClient<PlaylistWithEntriesResponse>("/getPlaylist", {
            query: { id: playlist.id },
          }),
        ),
      );

      const detailsToPersist: PlaylistWithEntries[] = [];
      const failedIds: string[] = [];

      results.forEach((result, index) => {
        if (result.status === "fulfilled" && result.value.data.playlist) {
          detailsToPersist.push(result.value.data.playlist);
        } else if (result.status === "rejected") {
          console.warn(
            `[metadataSync] failed to load playlist detail ${batch[index].id}:`,
            result.reason,
          );
          failedIds.push(batch[index].id);
        }
      });

      if (failedIds.length > 0) {
        const retryResults = await Promise.allSettled(
          failedIds.map((id) =>
            workerHttpClient<PlaylistWithEntriesResponse>("/getPlaylist", {
              query: { id },
            }),
          ),
        );
        retryResults.forEach((result) => {
          if (result.status === "fulfilled" && result.value.data.playlist) {
            detailsToPersist.push(result.value.data.playlist);
          }
        });
      }

      if (detailsToPersist.length > 0) {
        await this.db.playlistDetails.bulkPut(
          detailsToPersist.map(withStarredAt),
        );
      }

      this.#updateSyncState(
        "playlists",
        "t1",
        Math.min(offset + batch.length, playlists.length),
        playlists.length,
      );
    }
  }

  async syncAll(options?: SyncOptions): Promise<void> {
    await this.#authReady;
    const includeFullSongs = options?.includeFullSongs ?? true;
    const mode = options?.mode ?? "full";
    const generation = ++this.#syncGeneration;

    if (this.#abortController) {
      this.#abortController.abort();
    }

    this.#abortController = new AbortController();
    const signal = this.#abortController.signal;

    try {
      this.#updateSyncState("idle", undefined);

      if (!(await this.#shouldSkipTier("t1", mode))) {
        await this.#runT1(signal);
      }
      if (this.#syncGeneration !== generation) return;
      if (!(await this.#shouldSkipTier("t2", mode))) {
        await this.#runT2(signal);
      }
      if (this.#syncGeneration !== generation) return;
      if (includeFullSongs && !(await this.#shouldSkipTier("t3", mode))) {
        await this.#runT3(signal, options?.songCount ?? 100_000);
      }
      if (this.#syncGeneration !== generation) return;

      if (options?.includeCoverArt) {
        this.#updateSyncState("coverArt", undefined);
        await this.#syncCoverArt(
          options.useAlbumCoverForSongs ?? false,
          options.coverArtConcurrency ?? 1,
          (processed, total) => {
            this.#updateSyncState("coverArt", undefined, processed, total);
          },
        );
      }

      await this.db.syncState.put({
        key: "full-sync",
        lastSyncedAt: Date.now(),
      });
      this.#callbacks?.onLastSyncedAt(Date.now());
      this.#updateSyncState("done", undefined);
      this.#forceFlushSyncState();
      this.#callbacks?.onCacheIndexRefresh();
    } catch (err) {
      if (this.#syncGeneration !== generation) return;
      if (err instanceof DOMException && err.name === "AbortError") {
        this.#updateSyncState("cancelled", undefined);
      } else {
        console.error("Metadata sync failed:", err);
        this.#updateSyncState("error", undefined);
      }
      this.#forceFlushSyncState();
    } finally {
      if (this.#syncGeneration === generation) {
        this.#abortController = null;
      }
    }
  }

  async syncIncremental(options?: Omit<SyncOptions, "mode">): Promise<void> {
    await this.syncAll({ ...options, mode: "incremental" });
  }

  cancel(): void {
    if (this.#abortController) {
      this.#abortController.abort();
      this.#abortController = null;
    }
  }

  async #runT1(signal: AbortSignal): Promise<void> {
    this.#checkAborted(signal);
    this.#updateSyncState("genres", "t1");
    const genreResult = await workerHttpClient<GenresResponse>("/getGenres");
    this.#checkAborted(signal);
    const genres = genreResult.data.genres?.genre ?? [];
    await bulkPutInChunks(this.db.genres, genres, signal);

    this.#checkAborted(signal);
    this.#updateSyncState("playlists", "t1");
    const playlistsResult =
      await workerHttpClient<PlaylistsResponse>("/getPlaylists");
    this.#checkAborted(signal);
    const playlists = playlistsResult.data.playlists?.playlist ?? [];
    const playlistRows = playlists.map(withStarredAt);
    await bulkPutInChunks(this.db.playlists, playlistRows, signal);
    await this.#syncPlaylistDetails(playlistRows, signal);

    this.#checkAborted(signal);
    this.#updateSyncState("favorites", "t1");
    const starredResult =
      await workerHttpClient<FavoritesResponse>("/getStarred2");
    this.#checkAborted(signal);
    const starredSongs = starredResult.data.starred2?.song ?? [];
    const starredIds = new Set(
      starredSongs.map((song: { id: string }) => song.id),
    );

    const previouslyStarred = await this.db.songs
      .where("starredAt")
      .above(0)
      .primaryKeys();
    if (previouslyStarred.length > 0 && starredIds.size > 0) {
      const toUnstar = previouslyStarred.filter(
        (songId) => !starredIds.has(songId),
      );
      const localSongs = await this.db.songs
        .where("id")
        .anyOf(toUnstar)
        .toArray();
      const confirmedLocal = new Set(localSongs.map((s) => s.id));

      await Promise.all(
        toUnstar
          .filter((songId) => confirmedLocal.has(songId as string))
          .map((songId) =>
            this.db.songs.update(songId, {
              starred: undefined,
              starredAt: undefined,
            }),
          ),
      );
    }
    if (starredSongs.length > 0) {
      await bulkPutInChunks(
        this.db.songs,
        starredSongs.map(
          (s: { played?: string; starred?: string; [k: string]: unknown }) =>
            withPlayedAt(withStarredAt(s)),
        ),
        signal,
      );
    }

    await this.#recordTierCheckpoint("t1");
    this.#forceFlushSyncState();
    this.#callbacks?.onInvalidateQueries([
      ["playlists"],
      ["playlists", "single"],
      ["genres"],
      ["favorites", "count"],
      ["favorites", "list"],
      ["songs"],
    ]);
  }

  async #runT2(signal: AbortSignal): Promise<void> {
    this.#checkAborted(signal);
    this.#updateSyncState("artists", "t2");
    const artistsResult =
      await workerHttpClient<ArtistsResponse>("/getArtists");
    this.#checkAborted(signal);
    const artistsList: ISimilarArtist[] = [];
    artistsResult.data.artists.index.forEach(
      (item: { artist: ISimilarArtist[] }) => {
        artistsList.push(...item.artist);
      },
    );
    artistsList.sort((a, b) => a.name.localeCompare(b.name));

    await this.db.transaction("rw", this.db.artists, async () => {
      await this.db.artists.clear();
      await bulkPutInChunks(
        this.db.artists,
        artistsList.map(withStarredAt),
        signal,
      );
    });

    this.#checkAborted(signal);
    this.#updateSyncState("albums", "t2");
    const allAlbums: AlbumSummary[] = [];
    let albumOffset = 0;
    const albumPageSize = 500;
    let hasMoreAlbums = true;

    while (hasMoreAlbums) {
      this.#checkAborted(signal);

      const result = await workerHttpClient<AlbumListResponse>(
        "/getAlbumList2",
        {
          query: {
            type: "alphabeticalByName",
            size: albumPageSize.toString(),
            offset: albumOffset.toString(),
          },
        },
      );

      const list = result.data.albumList2.album;
      if (!list || list.length === 0) {
        hasMoreAlbums = false;
      } else {
        for (const album of list) {
          allAlbums.push({
            id: album.id,
            name: album.name,
            artist: album.artist,
            artistId: album.artistId,
            coverArt: album.coverArt,
            songCount: album.songCount,
            duration: album.duration,
            year: album.year,
            genre: album.genre,
            created: album.created,
            played: album.played,
            playCount: album.playCount,
            starred: album.starred,
          });
        }
        this.#updateSyncState(
          "albums",
          "t2",
          allAlbums.length,
          result.count || allAlbums.length,
        );
        albumOffset += albumPageSize;
        if (list.length < albumPageSize) {
          hasMoreAlbums = false;
        }
      }
    }

    await this.db.transaction("rw", this.db.albums, async () => {
      await this.db.albums.clear();
      await bulkPutInChunks(
        this.db.albums,
        allAlbums.map(withStarredAt),
        signal,
      );
    });

    await this.#recordTierCheckpoint("t2");
    this.#forceFlushSyncState();
    this.#callbacks?.onInvalidateQueries([["artists"], ["albums"]]);
  }

  async #runT3(signal: AbortSignal, songCount: number): Promise<void> {
    this.#checkAborted(signal);
    this.#updateSyncState("songs", "t3");

    const config = workerEnsureAuth();
    const searchAllQuery = config.serverType === "navidrome" ? '""' : "";

    const PAGE_SIZE = 500;
    const allSongs: ISong[] = [];
    let songOffset = 0;
    let hasMoreSongs = true;

    while (hasMoreSongs) {
      this.#checkAborted(signal);

      const searchResult = await workerHttpClient<ISearchResponse>("/search3", {
        query: {
          query: searchAllQuery,
          artistCount: "0",
          artistOffset: "0",
          albumCount: "0",
          albumOffset: "0",
          songCount: PAGE_SIZE.toString(),
          songOffset: songOffset.toString(),
        },
      });

      this.#checkAborted(signal);
      const page = searchResult.data.searchResult3?.song ?? [];
      if (page.length === 0) {
        hasMoreSongs = false;
      } else {
        allSongs.push(...page);
        songOffset += page.length;
        this.#updateSyncState("songs", "t3", allSongs.length, songCount);
        if (page.length < PAGE_SIZE) {
          hasMoreSongs = false;
        }
      }
    }

    const rows = allSongs.map(
      (s: { played?: string; starred?: string; [k: string]: unknown }) =>
        withPlayedAt(withStarredAt(s)),
    );
    await bulkPutInChunks(this.db.songs, rows, signal);

    if (allSongs.length > 0) {
      const serverIds = new Set(allSongs.map((s) => s.id));
      const allExistingKeys = await this.db.songs.toCollection().primaryKeys();
      const staleIds = allExistingKeys.filter(
        (id) => !serverIds.has(id as string),
      );
      const maxDeletions = Math.ceil(allSongs.length * 0.1);
      if (staleIds.length > 0 && staleIds.length <= maxDeletions) {
        await this.db.songs.bulkDelete(staleIds);
      } else if (staleIds.length > maxDeletions) {
        console.warn(
          `[sync] Skipping song stale deletion: ${staleIds.length} local songs missing from server, exceeds safety threshold of ${maxDeletions} (10%% of ${allSongs.length} synced songs). This likely indicates an incomplete sync.`,
        );
      }
    }

    this.#updateSyncState("songs", "t3", allSongs.length, allSongs.length);

    await this.#recordTierCheckpoint("t3");

    await this.#reconcileRemovedFromServer();

    this.#forceFlushSyncState();
    this.#callbacks?.onInvalidateQueries([
      ["songs"],
      ["favorites", "count"],
      ["favorites", "list"],
    ]);
  }

  async #syncCoverArt(
    useAlbumCoverForSongs: boolean,
    concurrency: number,
    onProgress?: (current: number, total: number) => void,
  ): Promise<void> {
    const coverArtIds = new Set<string>();
    await this.db.artists.each((a) => {
      if (a.coverArt) coverArtIds.add(a.coverArt);
      // Album details expose artist IDs while artist grids expose coverArt.
      // Cache both keys so either UI surface works offline.
      if (a.id) coverArtIds.add(a.id);
    });
    await this.db.albums.each((a) => {
      if (a.coverArt) coverArtIds.add(a.coverArt);
    });
    await this.db.playlists.each((p) => {
      if (p.coverArt) coverArtIds.add(p.coverArt);
    });
    if (!useAlbumCoverForSongs) {
      await this.db.songs.each((s) => {
        if (s.coverArt) coverArtIds.add(s.coverArt);
      });
    }

    const queue = Array.from(coverArtIds);
    await asyncPool(
      queue,
      concurrency,
      async (coverArtId) => {
        try {
          await this.#cacheCover(coverArtId, "700");
        } catch (err) {
          console.warn(
            `[cacheManager] failed to cache cover ${coverArtId}:`,
            err,
          );
        }
      },
      onProgress,
    );

    if (useAlbumCoverForSongs) {
      const albums = await this.db.albums.toArray();
      for (const album of albums) {
        if (!album.id || album.id === album.coverArt) continue;

        const key = coverKey(album.id);
        const existing = await this.db.cacheMeta.get(key);
        if (existing) continue;

        try {
          const blob = await cacheStorageGet(coverKey(album.coverArt));
          if (blob) {
            await cacheStoragePut(key, blob, blob.type || "image/jpeg");
            await this.db.cacheMeta.put({
              key,
              id: album.id,
              type: "cover",
              source: "explicit",
              coverSize: "700",
              sizeBytes: blob.size,
              cachedAt: Date.now(),
              lastAccessedAt: Date.now(),
            });
          } else {
            await this.#cacheCover(album.id, "700");
          }
        } catch (err) {
          console.warn(
            `[cacheManager] failed to alias cover ${album.id}:`,
            err,
          );
        }
      }
    }
  }

  async #cacheCover(coverArtId: string, size = "700"): Promise<void> {
    const key = coverKey(coverArtId);
    const existing = await this.db.cacheMeta.get(key);
    if (existing) {
      const sizeNum = Number.parseInt(size, 10);
      const existingSize = Number.parseInt(existing.coverSize || "0", 10);
      if (existingSize >= sizeNum) return;
    }

    const url = buildCoverArtUrl(workerEnsureAuth(), coverArtId, "album", size);
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(
        `Failed to fetch cover art for ${coverArtId}: ${response.status}`,
      );
    }
    const blob = await response.blob();

    await cacheStoragePut(key, blob, blob.type || "image/jpeg");
    await this.db.cacheMeta.put({
      key,
      id: coverArtId,
      type: "cover",
      source: "explicit",
      coverSize: size,
      sizeBytes: blob.size,
      cachedAt: Date.now(),
      lastAccessedAt: Date.now(),
    });
  }

  async #reconcileRemovedFromServer(): Promise<void> {
    const songCount = await this.db.songs.count();
    if (songCount === 0) return;

    const cachedItems = await this.db.cacheMeta
      .where("type")
      .equals("audio")
      .toArray();

    if (cachedItems.length === 0) return;

    const cachedIds = cachedItems.map((item) => item.id);
    const existingServerIds = new Set(
      await this.db.songs.where("id").anyOf(cachedIds).primaryKeys(),
    );

    const updates: CacheMetaRow[] = [];
    let removeCount = 0;
    for (const item of cachedItems) {
      const existsOnServer = existingServerIds.has(item.id);
      const shouldMarkRemoved = !existsOnServer;
      if (shouldMarkRemoved !== Boolean(item.removedFromServer)) {
        if (shouldMarkRemoved) removeCount++;
        updates.push({
          ...item,
          removedFromServer: shouldMarkRemoved || undefined,
        });
      }
    }

    if (removeCount > cachedItems.length * 0.5) {
      console.warn(
        `[sync] Skipping remove-reconciliation: ${removeCount}/${cachedItems.length} cached audio items would be marked as removed. The songs table is likely incomplete.`,
      );
      return;
    }

    if (updates.length > 0) {
      await this.db.cacheMeta.bulkPut(updates);
    }
  }
}
