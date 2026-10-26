/**
 * @deprecated Main-thread fallback for metadata sync.
 * The primary implementation is in sync.worker.ts (Web Worker).
 * This file is kept for environments where Web Workers are unavailable.
 */

import { libraryAccountKey } from "@/lib/library-owner";
import { replaceOwnedAlbums } from "@/service/cache/owned-albums";
import { httpClient } from "@/api/httpClient";
import { queryClient } from "@/lib/queryClient";
import { subsonic } from "@/service/subsonic";
import { useAppStore } from "@/store/app.store";
import { useCacheStore } from "@/store/cache.store";
import {
  libraryDb,
  type PlaylistRow,
  withPlayedAt,
  withStarredAt,
} from "@/store/library-db";
import type { SyncPhase, SyncTier } from "@/types/cache";
import type { ISearchResponse } from "@/types/responses/search";
import type { ISong } from "@/types/responses/song";
import { queryKeys } from "@/utils/queryKeys";

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

interface SyncOptions {
  includeCoverArt?: boolean;
  /**
   * Gate the T3 full-songs sync step (the expensive one on large
   * libraries). T1 + T2 always run regardless. Default: true.
   */
  includeFullSongs?: boolean;
  /**
   * `"full"` (default) — rebuild every tier unconditionally. Use when
   * the library identity changes (account switch, explicit user reset)
   * or when we need to be certain deletions propagate.
   *
   * `"incremental"` — skip any tier whose last checkpoint is still
   * inside its fresh window (see TIER_FRESH_WINDOW_MS). Suitable for
   * the startup / focus / manual-refresh triggers where "sync if it's
   * been a while" is the intended behavior and it's fine to trust the
   * current IDB for a few more minutes.
   *
   * Subsonic does not expose true per-item delta APIs on the
   * endpoints we need (only `getArtists` returns a `lastModified`
   * timestamp, and even there changes are at whole-table granularity),
   * so "incremental" is currently implemented as tier-level skipping
   * rather than row-level upsert. True delta can be layered on later
   * without changing the caller contract.
   */
  mode?: "full" | "incremental";
  coverArtConcurrency?: number;
}

const TIER_FRESH_WINDOW_MS: Record<SyncTier, number> = {
  t1: 5 * 60 * 1000, // 5 minutes — favorites/playlists/genres move fast
  t2: 30 * 60 * 1000, // 30 minutes — artists/albums change rarely
  t3: 2 * 60 * 60 * 1000, // 2 hours — full songs table; very expensive
};

/**
 * Rough upper bound on items per bulk write + per JS-thread turn.
 * Splitting the 100k+ songs payload into chunks keeps the main thread
 * responsive across the long-running T3 step (now superseded by
 * sync.worker.ts which runs off the main thread; this file is kept
 * as a main-thread fallback only).
 */
const BULK_CHUNK_SIZE = 2000;
const PLAYLIST_DETAIL_BATCH_SIZE = 10;

/** Yield control to the event loop between chunks of work. */
function yieldToMain(): Promise<void> {
  return new Promise((resolve) => {
    if (typeof requestIdleCallback === "function") {
      requestIdleCallback(() => resolve(), { timeout: 50 });
    } else {
      setTimeout(resolve, 0);
    }
  });
}

async function bulkPutInChunks<T, K>(
  table: { bulkPut: (rows: T[]) => Promise<K> },
  rows: T[],
  signal: AbortSignal,
): Promise<void> {
  for (let offset = 0; offset < rows.length; offset += BULK_CHUNK_SIZE) {
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
    await table.bulkPut(rows.slice(offset, offset + BULK_CHUNK_SIZE));
    if (offset + BULK_CHUNK_SIZE < rows.length) {
      await yieldToMain();
    }
  }
}

async function clearAndBulkPutInChunks<T, K>(
  table: { clear: () => Promise<void>; bulkPut: (rows: T[]) => Promise<K> },
  rows: T[],
  signal: AbortSignal,
): Promise<void> {
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  if (rows.length === 0) return;
  await table.clear();
  await bulkPutInChunks(table, rows, signal);
}

/**
 * Progressive, tiered metadata sync.
 *
 *  - T1 (seconds)       : user-visible essentials — favorites,
 *    playlists, genres. Users can meaningfully interact with the
 *    library once T1 lands.
 *  - T2 (minutes)       : library skeleton — every artist and every
 *    album summary, without per-song detail. Enables full browsing.
 *  - T3 (tens of minutes): the long tail — every song detail. Expensive
 *    on 100k+ libraries, so gated behind the `includeFullSongs` flag.
 *
 * Each tier is idempotent, writes its completion checkpoint to
 * libraryDb.syncState (key "tier:tN"), and invalidates the React
 * Query keys it touched so the UI refreshes as soon as data lands.
 * AbortController cancellation is honored at tier boundaries and at
 * every pagination step inside a tier.
 */
class MetadataSyncService {
  private abortController: AbortController | null = null;

  private updateSyncState(
    phase: SyncPhase,
    tier: SyncTier | undefined,
    processedItems = 0,
    totalItems = 0,
  ) {
    const { updateSyncState } = useCacheStore.getState().actions;
    updateSyncState({
      phase,
      tier,
      isSyncing: phase !== "done" && phase !== "error" && phase !== "cancelled",
      processedItems,
      totalItems,
      progress:
        totalItems > 0 ? Math.round((processedItems / totalItems) * 100) : 0,
    });
  }

  private checkAborted(signal: AbortSignal) {
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  }

  private async recordTierCheckpoint(tier: SyncTier) {
    await libraryDb.syncState.put({
      key: `tier:${tier}`,
      lastSyncedAt: Date.now(),
    });
  }

  private async syncPlaylistDetails(
    playlists: PlaylistRow[],
    signal: AbortSignal,
  ) {
    const playlistIds = new Set(playlists.map((playlist) => playlist.id));
    const existingIds = await libraryDb.playlistDetails
      .toCollection()
      .primaryKeys();
    const removedIds = existingIds.filter((id) => !playlistIds.has(id));

    if (
      removedIds.length > 0 &&
      playlists.length > 0 &&
      removedIds.length < existingIds.length
    ) {
      await libraryDb.playlistDetails.bulkDelete(removedIds);
    }

    for (
      let offset = 0;
      offset < playlists.length;
      offset += PLAYLIST_DETAIL_BATCH_SIZE
    ) {
      this.checkAborted(signal);

      const batch = playlists.slice(
        offset,
        offset + PLAYLIST_DETAIL_BATCH_SIZE,
      );
      const results = await Promise.allSettled(
        batch.map((playlist) => subsonic.playlists.getOne(playlist.id)),
      );

      const failedIds: string[] = [];
      results.forEach((result, index) => {
        if (result.status === "rejected") {
          console.warn(
            `[metadataSync] failed to load playlist detail ${batch[index].id}:`,
            result.reason,
          );
          failedIds.push(batch[index].id);
        }
      });

      if (failedIds.length > 0) {
        const retryResults = await Promise.allSettled(
          failedIds.map((id) => subsonic.playlists.getOne(id)),
        );
        retryResults.forEach((result, index) => {
          if (result.status === "rejected") {
            console.warn(
              `[metadataSync] retry failed for playlist detail ${failedIds[index]}:`,
              result.reason,
            );
          }
        });
      }

      this.updateSyncState(
        "playlists",
        "t1",
        Math.min(offset + batch.length, playlists.length),
        playlists.length,
      );

      if (offset + PLAYLIST_DETAIL_BATCH_SIZE < playlists.length) {
        await yieldToMain();
      }
    }
  }

  /**
   * True when the tier completed inside its fresh window and we're in
   * incremental mode. In "full" mode every tier always runs.
   */
  private async shouldSkipTier(
    tier: SyncTier,
    mode: "full" | "incremental",
  ): Promise<boolean> {
    if (mode === "full") return false;
    const entry = await libraryDb.syncState.get(`tier:${tier}`);
    if (!entry?.lastSyncedAt) return false;
    return Date.now() - entry.lastSyncedAt < TIER_FRESH_WINDOW_MS[tier];
  }

  async syncAll(options?: SyncOptions): Promise<void> {
    const includeFullSongs = options?.includeFullSongs ?? true;
    const mode = options?.mode ?? "full";

    if (this.abortController) {
      this.abortController.abort();
    }

    this.abortController = new AbortController();
    const signal = this.abortController.signal;

    try {
      this.updateSyncState("idle", undefined);

      if (!(await this.shouldSkipTier("t1", mode))) {
        await this.runT1(signal);
      }
      if (!(await this.shouldSkipTier("t2", mode))) {
        await this.runT2(signal);
      }
      if (includeFullSongs && !(await this.shouldSkipTier("t3", mode))) {
        await this.runT3(signal);
      }

      if (options?.includeCoverArt) {
        this.updateSyncState("coverArt", undefined);
        const { cacheManager } = await import("./cache-manager");
        const concurrency =
          options.coverArtConcurrency ??
          useCacheStore.getState().settings.coverArtConcurrency;
        await cacheManager.syncCoverArt((processed, total) => {
          this.updateSyncState("coverArt", undefined, processed, total);
        }, concurrency);
      }

      await libraryDb.syncState.put({
        key: "full-sync",
        lastSyncedAt: Date.now(),
      });
      useCacheStore.getState().actions.setLastSyncedAt(Date.now());
      this.updateSyncState("done", undefined);
    } catch (err) {
      if (err instanceof DOMException && err.name === "AbortError") {
        this.updateSyncState("cancelled", undefined);
      } else {
        console.error("Metadata sync failed:", err);
        this.updateSyncState("error", undefined);
      }
    } finally {
      this.abortController = null;
    }
  }

  /**
   * Shorthand for the startup / focus / manual-refresh triggers.
   * Equivalent to `syncAll({ mode: "incremental", ...overrides })`.
   */
  async syncIncremental(options?: Omit<SyncOptions, "mode">): Promise<void> {
    await this.syncAll({ ...options, mode: "incremental" });
  }

  /**
   * T1 — quick essentials (favorites, playlists, genres). Runs in
   * seconds even on large libraries. Upserts starred songs into
   * libraryDb.songs so the favorites view is populated before T3
   * brings in the full songs table.
   */
  private async runT1(signal: AbortSignal): Promise<void> {
    this.checkAborted(signal);
    this.updateSyncState("genres", "t1");
    const genres = await subsonic.genres.get();
    this.checkAborted(signal);
    await clearAndBulkPutInChunks(libraryDb.genres, genres ?? [], signal);

    this.checkAborted(signal);
    this.updateSyncState("playlists", "t1");
    const playlists = await subsonic.playlists.getAll();
    this.checkAborted(signal);
    const playlistRows = (playlists ?? []).map(withStarredAt);
    await clearAndBulkPutInChunks(libraryDb.playlists, playlistRows, signal);
    await this.syncPlaylistDetails(playlistRows, signal);

    this.checkAborted(signal);
    this.updateSyncState("favorites", "t1");
    const starred = await subsonic.songs.getFavoriteSongs();
    this.checkAborted(signal);
    const starredSongs = starred?.song ?? [];
    const starredIds = new Set(starredSongs.map((song) => song.id));

    // Reconcile starred state instead of pure upsert: otherwise songs
    // unstarred on the server remain falsely marked as favorites in
    // Dexie until a later full T3 rebuild happens. Only unstar songs
    // that we have locally (i.e., T3 has synced them and confirmed
    // they're no longer starred).
    const previouslyStarred = await libraryDb.songs
      .where("starredAt")
      .above(0)
      .primaryKeys();
    if (previouslyStarred.length > 0 && starredIds.size > 0) {
      const toUnstar = previouslyStarred.filter(
        (songId) => !starredIds.has(songId),
      );
      const localSongs = await libraryDb.songs
        .where("id")
        .anyOf(toUnstar)
        .toArray();
      const confirmedLocal = new Set(localSongs.map((s) => s.id));

      await Promise.all(
        toUnstar
          .filter((songId) => confirmedLocal.has(songId))
          .map((songId) =>
            libraryDb.songs.update(songId, {
              starred: undefined,
              starredAt: undefined,
            }),
          ),
      );
    }
    if (starredSongs.length > 0) {
      // Upsert only the currently starred songs so favorites are
      // visible from T1 onward even before the full songs table lands.
      await bulkPutInChunks(
        libraryDb.songs,
        starredSongs.map((s) => withPlayedAt(withStarredAt(s))),
        signal,
      );
    }

    await this.recordTierCheckpoint("t1");
    queryClient.invalidateQueries({ queryKey: queryKeys.playlist.all });
    queryClient.invalidateQueries({ queryKey: queryKeys.playlist.single });
    queryClient.invalidateQueries({ queryKey: queryKeys.genre });
    queryClient.invalidateQueries({ queryKey: queryKeys.favorites.count });
    queryClient.invalidateQueries({ queryKey: queryKeys.favorites.list });
    queryClient.invalidateQueries({ queryKey: queryKeys.song.all });
  }

  /**
   * T2 — library skeleton. Pulls every artist and every album summary
   * so browsing by artist / album / genre works end-to-end, even
   * offline. Does not fetch per-song detail.
   */
  private async runT2(signal: AbortSignal): Promise<void> {
    const owner = libraryAccountKey(useAppStore.getState().data);
    const checkOwner = () => {
      this.checkAborted(signal);
      if (owner !== libraryAccountKey(useAppStore.getState().data)) {
        throw new DOMException("Account changed", "AbortError");
      }
    };
    checkOwner();
    this.updateSyncState("artists", "t2");
    const artists = await subsonic.artists.getAll();
    this.checkAborted(signal);
    await clearAndBulkPutInChunks(
      libraryDb.artists,
      (artists ?? []).map(withStarredAt),
      signal,
    );

    this.checkAborted(signal);
    this.updateSyncState("albums", "t2");
    const allAlbums: AlbumSummary[] = [];
    let albumOffset = 0;
    const albumPageSize = 500;
    let hasMoreAlbums = true;

    while (hasMoreAlbums) {
      checkOwner();

      const result = await subsonic.albums.getAlbumList({
        type: "alphabeticalByName",
        size: albumPageSize,
        offset: albumOffset,
      });

      if (!result.list || result.list.length === 0) {
        hasMoreAlbums = false;
      } else {
        for (const album of result.list) {
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
        this.updateSyncState(
          "albums",
          "t2",
          allAlbums.length,
          result.albumsCount || allAlbums.length,
        );
        albumOffset += albumPageSize;
        if (result.list.length < albumPageSize) {
          hasMoreAlbums = false;
        }
      }
    }

    checkOwner();
    await replaceOwnedAlbums(libraryDb, allAlbums, owner, signal);

    await this.recordTierCheckpoint("t2");
    queryClient.invalidateQueries({ queryKey: queryKeys.artist.all });
    queryClient.invalidateQueries({ queryKey: queryKeys.album.all });
  }

  /**
   * T3 — the long tail: every song detail. Pages through
   * `search3?query=""` to fetch the complete song library.
   * Expected to take minutes to tens of minutes on large
   * libraries; gated behind `includeFullSongs` so users on big servers
   * who don't need offline-everywhere can opt out.
   */
  private async runT3(signal: AbortSignal): Promise<void> {
    this.checkAborted(signal);
    this.updateSyncState("songs", "t3");

    const serverType = useAppStore.getState().data.serverType;
    const searchAllQuery = serverType === "navidrome" ? '""' : "";
    const PAGE_SIZE = 500;
    const allSongs: ISong[] = [];
    let songOffset = 0;
    let hasMoreSongs = true;

    while (hasMoreSongs) {
      this.checkAborted(signal);
      const result = await httpClient<ISearchResponse>("/search3", {
        method: "GET",
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
      this.checkAborted(signal);

      const page = result.data.searchResult3?.song ?? [];
      if (page.length === 0) {
        hasMoreSongs = false;
      } else {
        allSongs.push(...page);
        songOffset += page.length;
        this.updateSyncState("songs", "t3", allSongs.length, allSongs.length);
        if (page.length < PAGE_SIZE) {
          hasMoreSongs = false;
        }
        if (allSongs.length % 2000 === 0) {
          await yieldToMain();
        }
      }
    }

    const rows = allSongs.map((s) => withPlayedAt(withStarredAt(s)));
    await bulkPutInChunks(libraryDb.songs, rows, signal);

    if (rows.length > 0) {
      const serverIds = new Set(rows.map((s) => s.id));
      const allExistingKeys = await libraryDb.songs
        .toCollection()
        .primaryKeys();
      const staleIds = allExistingKeys.filter((id) => !serverIds.has(id));
      const maxDeletions = Math.ceil(rows.length * 0.1);
      if (staleIds.length > 0 && staleIds.length <= maxDeletions) {
        await libraryDb.songs.bulkDelete(staleIds);
      } else if (staleIds.length > maxDeletions) {
        console.warn(
          `[metadataSync] Skipping song stale deletion: ${staleIds.length} local songs missing from server, exceeds safety threshold of ${maxDeletions} (10%% of ${rows.length} synced songs). This likely indicates an incomplete sync.`,
        );
      }
    }

    this.updateSyncState("songs", "t3", rows.length, rows.length);

    await this.recordTierCheckpoint("t3");

    // P7.3: after a fresh songs table, any cached audio whose songId
    // disappeared from the server is an "orphan". Flag them so the
    // UI can show a "Removed from server" label without deleting the
    // local blob. Runs inline here rather than at `syncAll` tail so
    // we only reconcile after the songs table is actually current.
    const { cacheManager } = await import("./cache-manager");
    await cacheManager.reconcileRemovedFromServer();

    queryClient.invalidateQueries({ queryKey: queryKeys.song.all });
    queryClient.invalidateQueries({ queryKey: queryKeys.favorites.count });
    queryClient.invalidateQueries({ queryKey: queryKeys.favorites.list });
  }

  cancel(): void {
    if (this.abortController) {
      this.abortController.abort();
      this.abortController = null;
    }
  }
}

export const metadataSyncService = new MetadataSyncService();
