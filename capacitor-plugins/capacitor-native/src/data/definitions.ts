import type { Plugin } from "@capacitor/core";

export const NATIVE_DATA_PLUGIN_NAME = "AonsokuNativeData";

// --- Initialization ---

export interface InitializeResult {
  ready: boolean;
  needsMigration: boolean;
}

export interface BulkImportData {
  artists?: string;
  albums?: string;
  songs?: string;
  playlists?: string;
  playlistDetails?: string;
  genres?: string;
  cacheMeta?: string;
  lyrics?: string;
  syncState?: string;
}

// --- Sync ---

export interface NativeSyncOptions {
  includeCoverArt?: boolean;
  includeFullSongs?: boolean;
  coverArtConcurrency?: number;
  useAlbumCoverForSongs?: boolean;
}

export interface NativeSyncState {
  phase: string;
  tier?: string;
  isSyncing: boolean;
  progress: number;
  processedItems: number;
  totalItems: number;
}

// --- Pagination ---

export interface PaginatedQuery {
  limit: number;
  offset: number;
}

export interface PaginatedResult<T> {
  items: T[];
  total: number;
  hasMore: boolean;
}

// --- Filters ---

export interface ArtistFilter {
  search?: string;
  starredOnly?: boolean;
  sortBy?: "name" | "starredAt";
  sortOrder?: "asc" | "desc";
}

export interface AlbumFilter {
  search?: string;
  artistId?: string;
  genre?: string;
  fromYear?: number;
  toYear?: number;
  starredOnly?: boolean;
  sortBy?:
    | "name"
    | "artist"
    | "year"
    | "created"
    | "starredAt"
    | "playCount"
    | "random";
  sortOrder?: "asc" | "desc";
}

export interface SongFilter {
  search?: string;
  albumId?: string;
  artistId?: string;
  genre?: string;
  starredOnly?: boolean;
  sortBy?:
    | "title"
    | "artist"
    | "album"
    | "starredAt"
    | "playCount"
    | "playedAt"
    | "created";
  sortOrder?: "asc" | "desc";
}

export interface SearchOptions {
  query: string;
  artistCount?: number;
  albumCount?: number;
  songCount?: number;
}

// --- Data Types ---

export interface NativeArtist {
  id: string;
  name: string;
  albumCount: number;
  coverArt?: string;
  artistImageUrl?: string;
  starred?: string;
  starredAt?: number;
}

export interface NativeAlbum {
  id: string;
  name: string;
  artist: string;
  artistId?: string;
  coverArt?: string;
  songCount: number;
  duration: number;
  year?: number;
  genre?: string;
  created?: string;
  played?: string;
  playCount?: number;
  starred?: string;
  starredAt?: number;
}

export interface NativeSong {
  id: string;
  parent?: string;
  title: string;
  album?: string;
  artist?: string;
  track?: number;
  year?: number;
  genre?: string;
  coverArt?: string;
  size?: number;
  contentType?: string;
  suffix?: string;
  duration: number;
  bitRate?: number;
  path?: string;
  playCount?: number;
  discNumber?: number;
  created?: string;
  albumId?: string;
  artistId?: string;
  played?: string;
  starred?: string;
  starredAt?: number;
  playedAt?: number;
  bpm?: number;
  comment?: string;
  sortName?: string;
  mediaType?: string;
  musicBrainzId?: string;
  genres?: { name: string }[];
  replayGain?: {
    trackGain?: number;
    trackPeak?: number;
    albumGain?: number;
    albumPeak?: number;
  };
}

export interface NativePlaylist {
  id: string;
  name: string;
  comment?: string;
  songCount: number;
  duration: number;
  isPublic?: boolean;
  owner?: string;
  created?: string;
  changed?: string;
  coverArt?: string;
  starred?: string;
  starredAt?: number;
}

export interface NativePlaylistWithEntries extends NativePlaylist {
  entry?: NativeSong[];
}

export interface NativeGenre {
  value: string;
  songCount?: number;
  albumCount?: number;
}

export interface NativeAlbumWithSongs extends NativeAlbum {
  song?: NativeSong[];
}

export interface NativeSearchResult {
  artists: NativeArtist[];
  albums: NativeAlbum[];
  songs: NativeSong[];
}

// --- Lyrics ---

export interface NativeLyricsEntry {
  songId: string;
  content: string;
  synced?: boolean;
  cachedAt: number;
  lastAccessedAt: number;
}

export interface StoreLyricsOptions {
  songId: string;
  content: string;
  synced: boolean;
}

// --- Cache Stats ---

export interface NativeCacheStats {
  totalItems: number;
  totalSizeBytes: number;
  audioCount: number;
  coverCount: number;
}

// --- Cover Image Cache ---

export interface NativeStoreCoverImageOptions {
  coverArtId: string;
  dataBase64: string;
  contentType: string;
  coverSize: string;
}

export interface NativeCachedCoverImageFile {
  coverArtId: string;
  uri: string;
  contentType?: string;
  sizeBytes?: number;
  coverSize?: string;
}

export interface NativeResolveCoverImageResult {
  file: NativeCachedCoverImageFile | null;
}

export interface NativeCoverImageSizeResult {
  sizeBytes: number | null;
  coverSize: string | null;
}

export interface NativeDeleteCoverImageResult {
  deleted: boolean;
}

export interface NativeClearCoverImagesResult {
  deletedCount: number;
}

export interface NativeDownloadCoverImageOptions {
  coverArtId: string;
  size: string;
}

export interface NativeDownloadAvatarOptions {
  username: string;
  size: string;
}

// --- Plugin Interface ---

export interface AonsokuNativeDataPlugin extends Plugin {
  initialize(): Promise<InitializeResult>;
  importBulk(options: BulkImportData): Promise<void>;

  syncAll(options?: NativeSyncOptions): Promise<void>;
  syncIncremental(options?: NativeSyncOptions): Promise<void>;
  cancelSync(): Promise<void>;
  getSyncState(): Promise<NativeSyncState>;

  getArtists(
    options: PaginatedQuery & ArtistFilter,
  ): Promise<PaginatedResult<NativeArtist>>;
  getArtist(options: { id: string }): Promise<NativeArtist | null>;

  getAlbums(
    options: PaginatedQuery & AlbumFilter,
  ): Promise<PaginatedResult<NativeAlbum>>;
  getAlbum(options: { id: string }): Promise<NativeAlbumWithSongs | null>;

  getSongs(
    options: PaginatedQuery & SongFilter,
  ): Promise<PaginatedResult<NativeSong>>;

  getPlaylists(
    options?: PaginatedQuery,
  ): Promise<PaginatedResult<NativePlaylist>>;
  getPlaylist(options: {
    id: string;
  }): Promise<NativePlaylistWithEntries | null>;

  getGenres(): Promise<{ items: NativeGenre[] }>;

  getFavorites(
    options: PaginatedQuery & { type: "songs" | "albums" | "artists" },
  ): Promise<PaginatedResult<NativeSong | NativeAlbum | NativeArtist>>;

  search(options: SearchOptions): Promise<NativeSearchResult>;

  getLyrics(options: { songId: string }): Promise<NativeLyricsEntry | null>;
  storeLyrics(options: StoreLyricsOptions): Promise<void>;
  getCacheStats(): Promise<NativeCacheStats>;

  isDataAvailableOffline(): Promise<{
    available: boolean;
    lastSyncedAt: number | null;
  }>;

  // Cover Image Cache
  storeCoverImage(
    options: NativeStoreCoverImageOptions,
  ): Promise<NativeResolveCoverImageResult>;
  resolveCoverImage(options: {
    coverArtId: string;
  }): Promise<NativeResolveCoverImageResult>;
  getCoverImageSize(options: {
    coverArtId: string;
  }): Promise<NativeCoverImageSizeResult>;
  deleteCoverImage(options: {
    coverArtId: string;
  }): Promise<NativeDeleteCoverImageResult>;
  clearCoverImages(): Promise<NativeClearCoverImagesResult>;
  downloadCoverImage(
    options: NativeDownloadCoverImageOptions,
  ): Promise<NativeResolveCoverImageResult>;
  downloadAvatar(
    options: NativeDownloadAvatarOptions,
  ): Promise<NativeResolveCoverImageResult>;
}
