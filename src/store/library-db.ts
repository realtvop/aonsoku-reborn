import Dexie, { type Table } from "dexie";
import { get as idbGet } from "idb-keyval";
import { cacheIndexStore, offlineLibraryStore } from "@/store/idb";
import type { CacheMetaSource } from "@/types/cache";
import type { Albums } from "@/types/responses/album";
import type { ISimilarArtist } from "@/types/responses/artist";
import type { Genre } from "@/types/responses/genre";
import type { Playlist, PlaylistWithEntries } from "@/types/responses/playlist";
import type { ISong } from "@/types/responses/song";

// ─── Row types ────────────────────────────────────────────────────────
// Row types extend Subsonic response types and add indexable numeric
// fields derived from ISO date strings. Dexie cannot index on string
// dates reliably; epoch ms gives us range queries (above/below/between).

export interface ArtistRow extends ISimilarArtist {
  starredAt?: number;
}

export interface AlbumRow extends Albums {
  /** Account/server that supplied this row in a completed metadata sync. */
  libraryOwner?: string;
  starredAt?: number;
}

export interface SongRow extends ISong {
  starredAt?: number;
  playedAt?: number;
}

export interface PlaylistRow extends Playlist {
  // Navidrome supports starring playlists; base Subsonic schema does not
  // declare it, so keep optional here.
  starred?: string;
  starredAt?: number;
}

export interface PlaylistDetailRow extends PlaylistWithEntries {
  starred?: string;
  starredAt?: number;
}

export type GenreRow = Genre;

export interface CacheMetaRow {
  key: string;
  id: string;
  type: "audio" | "cover" | "album" | "playlist";
  source: CacheMetaSource;
  /** Rule names (P5) that caused a smart-cached item to land here. */
  triggers?: string[];
  /** For cover entries: the resolution (e.g. "700") that was requested. */
  coverSize?: string;
  /** Stable content revision for a cached cover. */
  revision?: string;
  sizeBytes: number;
  cachedAt: number;
  lastAccessedAt: number;
  /** True when a synced explicit download no longer exists on server (P7.3). */
  removedFromServer?: boolean;
}

export interface LyricsRow {
  songId: string;
  content: string;
  synced?: boolean;
  cachedAt: number;
  lastAccessedAt: number;
}

export interface SyncStateRow {
  /**
   * Key examples:
   *  - "tier:t1" | "tier:t2" | "tier:t3" — tier completion
   *  - "table:artists" | "table:albums" | ... — per-table lastSyncedAt
   *  - "_legacy" — timestamp migrated from old offline-sync-timestamp
   *  - "_migrated_v1" — marker for one-time legacy migration
   */
  key: string;
  lastSyncedAt?: number;
  phase?: string;
  checkpoint?: unknown;
}

// ─── Dexie database ───────────────────────────────────────────────────

export class LibraryDB extends Dexie {
  artists!: Table<ArtistRow, string>;
  albums!: Table<AlbumRow, string>;
  songs!: Table<SongRow, string>;
  playlists!: Table<PlaylistRow, string>;
  playlistDetails!: Table<PlaylistDetailRow, string>;
  genres!: Table<GenreRow, string>;
  cacheMeta!: Table<CacheMetaRow, string>;
  lyrics!: Table<LyricsRow, string>;
  syncState!: Table<SyncStateRow, string>;

  constructor(name = "aonsoku-library") {
    super(name);
    this.version(1).stores({
      artists: "id, name, starredAt",
      albums: "id, artistId, name, year, genre, starredAt, created",
      songs: "id, albumId, artistId, title, starredAt, playCount, playedAt",
      playlists: "id, name, starredAt",
      genres: "value",
      cacheMeta: "key, id, type, source, lastAccessedAt, cachedAt",
      lyrics: "songId, lastAccessedAt",
      syncState: "key",
    });
    this.version(2).stores({
      artists: "id, name, starredAt",
      albums: "id, artistId, name, year, genre, starredAt, created",
      songs: "id, albumId, artistId, title, starredAt, playCount, playedAt",
      playlists: "id, name, starredAt",
      playlistDetails: "id, name, starredAt",
      genres: "value",
      cacheMeta: "key, id, type, source, lastAccessedAt, cachedAt",
      lyrics: "songId, lastAccessedAt",
      syncState: "key",
    });
  }
}

export const libraryDb = new LibraryDB();

// ─── Normalization helpers ────────────────────────────────────────────

function toEpoch(iso: string | undefined | null): number | undefined {
  if (!iso) return undefined;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? undefined : ms;
}

export function withStarredAt<T extends { starred?: string }>(
  row: T,
): T & { starredAt?: number } {
  return { ...row, starredAt: toEpoch(row.starred) };
}

export function withPlayedAt<T extends { played?: string }>(
  row: T,
): T & { playedAt?: number } {
  return { ...row, playedAt: toEpoch(row.played) };
}

// ─── Legacy migration ─────────────────────────────────────────────────

const MIGRATION_KEY = "_migrated_v1";
const LEGACY_TIMESTAMP_KEY = "_legacy";

const LEGACY_KEYS = {
  genres: "offline-genres",
  artists: "offline-artists",
  albums: "offline-albums",
  songs: "offline-songs",
  playlists: "offline-playlists",
  timestamp: "offline-sync-timestamp",
} as const;

const LEGACY_CACHE_INDEX_KEY = "cache-index-v1";

interface LegacyCachedItemMeta {
  id: string;
  type: "audio" | "cover" | "album" | "playlist";
  sizeBytes: number;
  cachedAt: number;
  lastAccessedAt: number;
}

/**
 * Copy data from the pre-Dexie `offline-library` + `cache-index` stores
 * into the new typed schema. Runs at most once (marked via syncState).
 * Legacy stores are left intact so a rollback to the previous build can
 * still read them.
 *
 * Returns true when migration actually ran, false when already migrated
 * or when the copy failed (caller may retry on next startup).
 */
export async function migrateLegacyStoresIfNeeded(): Promise<boolean> {
  const existing = await libraryDb.syncState.get(MIGRATION_KEY);
  if (existing) return false;

  try {
    const [genres, artists, albums, songs, playlists, timestamp, cacheIndex] =
      await Promise.all([
        idbGet<Genre[]>(LEGACY_KEYS.genres, offlineLibraryStore),
        idbGet<ISimilarArtist[]>(LEGACY_KEYS.artists, offlineLibraryStore),
        idbGet<AlbumRow[]>(LEGACY_KEYS.albums, offlineLibraryStore),
        idbGet<ISong[]>(LEGACY_KEYS.songs, offlineLibraryStore),
        idbGet<PlaylistRow[]>(LEGACY_KEYS.playlists, offlineLibraryStore),
        idbGet<number>(LEGACY_KEYS.timestamp, offlineLibraryStore),
        idbGet<Record<string, LegacyCachedItemMeta>>(
          LEGACY_CACHE_INDEX_KEY,
          cacheIndexStore,
        ),
      ]);

    await libraryDb.transaction(
      "rw",
      [
        libraryDb.genres,
        libraryDb.artists,
        libraryDb.albums,
        libraryDb.songs,
        libraryDb.playlists,
        libraryDb.cacheMeta,
        libraryDb.syncState,
      ],
      async () => {
        if (genres?.length) {
          await libraryDb.genres.bulkPut(genres);
        }
        if (artists?.length) {
          await libraryDb.artists.bulkPut(artists.map(withStarredAt));
        }
        if (albums?.length) {
          await libraryDb.albums.bulkPut(albums.map(withStarredAt));
        }
        if (songs?.length) {
          await libraryDb.songs.bulkPut(
            songs.map((s) => withPlayedAt(withStarredAt(s))),
          );
        }
        if (playlists?.length) {
          await libraryDb.playlists.bulkPut(playlists.map(withStarredAt));
        }
        if (typeof timestamp === "number") {
          await libraryDb.syncState.put({
            key: LEGACY_TIMESTAMP_KEY,
            lastSyncedAt: timestamp,
          });
        }
        if (cacheIndex) {
          const rows: CacheMetaRow[] = Object.entries(cacheIndex).map(
            ([key, meta]) => ({
              key,
              id: meta.id,
              type: meta.type,
              // Legacy entries predate the explicit/smart/lru split; mark
              // them as explicit so they are protected from auto-eviction
              // until the user manually clears them.
              source: "explicit" as const,
              sizeBytes: meta.sizeBytes,
              cachedAt: meta.cachedAt,
              lastAccessedAt: meta.lastAccessedAt,
            }),
          );
          if (rows.length) {
            await libraryDb.cacheMeta.bulkPut(rows);
          }
        }
        await libraryDb.syncState.put({
          key: MIGRATION_KEY,
          lastSyncedAt: Date.now(),
        });
      },
    );
    return true;
  } catch (err) {
    console.error("[library-db] legacy migration failed:", err);
    return false;
  }
}

export async function clearLibraryData(): Promise<void> {
  await libraryDb.transaction(
    "rw",
    [
      libraryDb.artists,
      libraryDb.albums,
      libraryDb.songs,
      libraryDb.playlists,
      libraryDb.playlistDetails,
      libraryDb.genres,
      libraryDb.syncState,
    ],
    async () => {
      await Promise.all([
        libraryDb.artists.clear(),
        libraryDb.albums.clear(),
        libraryDb.songs.clear(),
        libraryDb.playlists.clear(),
        libraryDb.playlistDetails.clear(),
        libraryDb.genres.clear(),
        libraryDb.syncState.clear(),
      ]);
    },
  );
}

// ─── Test utilities (not for production use) ─────────────────────────

/** Clear every store in libraryDb. Intended for unit tests only. */
export async function _resetLibraryDbForTests(): Promise<void> {
  await libraryDb.transaction(
    "rw",
    [
      libraryDb.artists,
      libraryDb.albums,
      libraryDb.songs,
      libraryDb.playlists,
      libraryDb.playlistDetails,
      libraryDb.genres,
      libraryDb.cacheMeta,
      libraryDb.lyrics,
      libraryDb.syncState,
    ],
    async () => {
      await Promise.all([
        libraryDb.artists.clear(),
        libraryDb.albums.clear(),
        libraryDb.songs.clear(),
        libraryDb.playlists.clear(),
        libraryDb.playlistDetails.clear(),
        libraryDb.genres.clear(),
        libraryDb.cacheMeta.clear(),
        libraryDb.lyrics.clear(),
        libraryDb.syncState.clear(),
      ]);
    },
  );
}
