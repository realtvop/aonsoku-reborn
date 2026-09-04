import { WebPlugin } from "@capacitor/core";
import type {
  AlbumFilter,
  AonsokuNativeDataPlugin,
  ArtistFilter,
  BulkImportData,
  InitializeResult,
  NativeAlbum,
  NativeAlbumWithSongs,
  NativeArtist,
  NativeCacheStats,
  NativeGenre,
  NativeLyricsEntry,
  NativePlaylist,
  NativePlaylistWithEntries,
  NativeSearchResult,
  NativeSong,
  NativeSyncOptions,
  NativeSyncState,
  PaginatedQuery,
  PaginatedResult,
  SearchOptions,
  SongFilter,
  StoreLyricsOptions,
} from "./definitions";

const UNAVAILABLE =
  "AonsokuNativeData is only available on native Capacitor platforms";

export class AonsokuNativeDataWeb
  extends WebPlugin
  implements AonsokuNativeDataPlugin
{
  async initialize(): Promise<InitializeResult> {
    throw new Error(UNAVAILABLE);
  }
  async importBulk(_options: BulkImportData): Promise<void> {
    throw new Error(UNAVAILABLE);
  }
  async syncAll(_options?: NativeSyncOptions): Promise<void> {
    throw new Error(UNAVAILABLE);
  }
  async syncIncremental(_options?: NativeSyncOptions): Promise<void> {
    throw new Error(UNAVAILABLE);
  }
  async cancelSync(): Promise<void> {
    throw new Error(UNAVAILABLE);
  }
  async getSyncState(): Promise<NativeSyncState> {
    throw new Error(UNAVAILABLE);
  }
  async getArtists(
    _options: PaginatedQuery & ArtistFilter,
  ): Promise<PaginatedResult<NativeArtist>> {
    throw new Error(UNAVAILABLE);
  }
  async getArtist(_options: { id: string }): Promise<NativeArtist | null> {
    throw new Error(UNAVAILABLE);
  }
  async getAlbums(
    _options: PaginatedQuery & AlbumFilter,
  ): Promise<PaginatedResult<NativeAlbum>> {
    throw new Error(UNAVAILABLE);
  }
  async getAlbum(_options: {
    id: string;
  }): Promise<NativeAlbumWithSongs | null> {
    throw new Error(UNAVAILABLE);
  }
  async getSongs(
    _options: PaginatedQuery & SongFilter,
  ): Promise<PaginatedResult<NativeSong>> {
    throw new Error(UNAVAILABLE);
  }
  async getPlaylists(
    _options?: PaginatedQuery,
  ): Promise<PaginatedResult<NativePlaylist>> {
    throw new Error(UNAVAILABLE);
  }
  async getPlaylist(_options: {
    id: string;
  }): Promise<NativePlaylistWithEntries | null> {
    throw new Error(UNAVAILABLE);
  }
  async getGenres(): Promise<{ items: NativeGenre[] }> {
    throw new Error(UNAVAILABLE);
  }
  async getFavorites(
    _options: PaginatedQuery & { type: "songs" | "albums" | "artists" },
  ): Promise<PaginatedResult<NativeSong | NativeAlbum | NativeArtist>> {
    throw new Error(UNAVAILABLE);
  }
  async search(_options: SearchOptions): Promise<NativeSearchResult> {
    throw new Error(UNAVAILABLE);
  }
  async getLyrics(_options: {
    songId: string;
  }): Promise<NativeLyricsEntry | null> {
    throw new Error(UNAVAILABLE);
  }
  async storeLyrics(_options: StoreLyricsOptions): Promise<void> {
    throw new Error(UNAVAILABLE);
  }
  async getCacheStats(): Promise<NativeCacheStats> {
    throw new Error(UNAVAILABLE);
  }
  async isDataAvailableOffline(): Promise<{
    available: boolean;
    lastSyncedAt: number | null;
  }> {
    throw new Error(UNAVAILABLE);
  }
}
