import {
  mkdir,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import type {
  AlbumFilter,
  ArtistFilter,
  NativeAlbum,
  NativeArtist,
  NativeGenre,
  NativePlaylist,
  NativePlaylistWithEntries,
  NativeSearchResult,
  NativeSong,
  NativeSyncState,
  PaginatedQuery,
  SongFilter,
} from "@aonsoku/capacitor-native/data";
import { app } from "electron";
import { AonsokuStore } from "../../core/store";
import type { DesktopNativeBridgeService } from "../bridge/service";

interface DataState {
  artists: NativeArtist[];
  albums: NativeAlbum[];
  songs: NativeSong[];
  playlists: NativePlaylist[];
  playlistDetails: Record<string, NativePlaylistWithEntries>;
  genres: NativeGenre[];
  lyrics: Record<
    string,
    {
      content: string;
      synced: boolean;
      cachedAt: number;
      lastAccessedAt: number;
    }
  >;
  lastSyncedAt?: number;
  coverFiles: Record<
    string,
    { fileName: string; contentType: string; coverSize: string }
  >;
}

const defaults: DataState = {
  artists: [],
  albums: [],
  songs: [],
  playlists: [],
  playlistDetails: {},
  genres: [],
  lyrics: {},
  coverFiles: {},
};

function paginate<T>(items: T[], { limit, offset }: PaginatedQuery) {
  return {
    items: items.slice(offset, offset + limit),
    total: items.length,
    hasMore: offset + limit < items.length,
  };
}

function text(value: unknown): string {
  return String(value ?? "").toLocaleLowerCase();
}

export class DesktopNativeDataService {
  private readonly store = new AonsokuStore<DataState>({
    name: "native-library",
    defaults,
  });
  private syncState: NativeSyncState = {
    phase: "idle",
    isSyncing: false,
    progress: 0,
    processedItems: 0,
    totalItems: 0,
  };
  private cancelled = false;

  constructor(
    private readonly bridge: DesktopNativeBridgeService,
    private readonly emit: (event: string, payload: unknown) => void,
  ) {}

  initialize() {
    return { ready: true, needsMigration: false };
  }

  importBulk(): void {}

  getSyncState() {
    return this.syncState;
  }

  cancelSync(): void {
    this.cancelled = true;
  }

  async syncAll(options?: { includeFullSongs?: boolean }): Promise<void> {
    await this.sync(false, options?.includeFullSongs ?? false);
  }

  async syncIncremental(): Promise<void> {
    await this.sync(true, false);
  }

  private updateSyncState(state: Partial<NativeSyncState>): void {
    this.syncState = { ...this.syncState, ...state };
    this.emit("syncStateChanged", this.syncState);
  }

  private async sync(
    _incremental: boolean,
    includeFullSongs: boolean,
  ): Promise<void> {
    if (this.syncState.isSyncing) return;
    this.cancelled = false;
    this.updateSyncState({ isSyncing: true, phase: "genres", progress: 0 });
    try {
      const [
        genresResponse,
        playlistsResponse,
        starredResponse,
        artistsResponse,
      ] = await Promise.all([
        this.bridge.request({ path: "/getGenres.view" }),
        this.bridge.request({ path: "/getPlaylists.view" }),
        this.bridge.request({ path: "/getStarred2.view" }),
        this.bridge.request({ path: "/getArtists.view" }),
      ]);
      if (this.cancelled) return;

      const genres = ((genresResponse.data.genres as { genre?: NativeGenre[] })
        ?.genre ?? []) as NativeGenre[];
      const playlists = ((
        playlistsResponse.data.playlists as {
          playlist?: NativePlaylist[];
        }
      )?.playlist ?? []) as NativePlaylist[];
      const starred = (starredResponse.data.starred2 ?? {}) as {
        song?: NativeSong[];
      };
      const artistIndexes = (
        (
          artistsResponse.data.artists as {
            index?: Array<{ artist?: NativeArtist[] }>;
          }
        )?.index ?? []
      ).flatMap((index) => index.artist ?? []);

      this.store.set({ genres, playlists, artists: artistIndexes });
      this.updateSyncState({ phase: "albums", progress: 0.3 });

      const albums: NativeAlbum[] = [];
      for (let offset = 0; !this.cancelled; offset += 500) {
        const response = await this.bridge.request({
          path: "/getAlbumList2.view",
          query: { type: "alphabeticalByName", size: 500, offset },
        });
        const page = ((
          response.data.albumList2 as {
            album?: NativeAlbum[];
          }
        )?.album ?? []) as NativeAlbum[];
        albums.push(...page);
        this.updateSyncState({ processedItems: albums.length });
        if (page.length < 500) break;
      }
      if (this.cancelled) return;

      if (!includeFullSongs) {
        this.store.set({
          albums,
          songs: this.mergeStarredSongs(
            this.store.get("songs"),
            starred.song ?? [],
          ),
          lastSyncedAt: Date.now(),
        });
        this.emit("dataChanged", {
          tables: [
            "genres",
            "playlists",
            "favorites",
            "artists",
            "albums",
            "songs",
          ],
        });
        this.updateSyncState({ phase: "done", progress: 1 });
        return;
      }

      const songs: NativeSong[] = [];
      this.updateSyncState({ phase: "songs", progress: 0.6 });
      for (let offset = 0; !this.cancelled; offset += 500) {
        const response = await this.bridge.request({
          path: "/search3.view",
          query: {
            query:
              this.bridge.getCredentials()?.serverType === "navidrome"
                ? '""'
                : "",
            artistCount: 0,
            albumCount: 0,
            songCount: 500,
            songOffset: offset,
          },
        });
        const page = ((
          response.data.searchResult3 as {
            song?: NativeSong[];
          }
        )?.song ?? []) as NativeSong[];
        songs.push(...page);
        this.updateSyncState({ processedItems: songs.length });
        if (page.length < 500) break;
      }
      const mergedSongs = this.mergeStarredSongs(songs, starred.song ?? []);
      this.store.set({ albums, songs: mergedSongs, lastSyncedAt: Date.now() });
      this.emit("dataChanged", {
        tables: [
          "genres",
          "playlists",
          "favorites",
          "artists",
          "albums",
          "songs",
        ],
      });
      this.updateSyncState({ phase: "done", progress: 1 });
    } catch (error) {
      this.updateSyncState({ phase: "error" });
      throw error;
    } finally {
      this.updateSyncState({ isSyncing: false });
    }
  }

  private mergeStarredSongs(
    songs: NativeSong[],
    starred: NativeSong[],
  ): NativeSong[] {
    const starredById = new Map(starred.map((song) => [song.id, song]));
    const merged = songs.map((song) => ({
      ...song,
      ...(starredById.get(song.id)?.starred
        ? { starred: starredById.get(song.id)?.starred }
        : {}),
    }));
    const known = new Set(merged.map((song) => song.id));
    return [...merged, ...starred.filter((song) => !known.has(song.id))];
  }

  getArtists(options: PaginatedQuery & ArtistFilter) {
    let items = [...this.store.get("artists")];
    if (options.search)
      items = items.filter((item) =>
        text(item.name).includes(text(options.search)),
      );
    if (options.starredOnly)
      items = items.filter((item) => Boolean(item.starred));
    items.sort(
      (a, b) =>
        text(a.name).localeCompare(text(b.name)) *
        (options.sortOrder === "desc" ? -1 : 1),
    );
    return paginate(items, options);
  }

  getArtist({ id }: { id: string }) {
    return this.store.get("artists").find((item) => item.id === id) ?? null;
  }

  getAlbums(options: PaginatedQuery & AlbumFilter) {
    let items = [...this.store.get("albums")];
    if (options.search)
      items = items.filter(
        (item) =>
          text(item.name).includes(text(options.search)) ||
          text(item.artist).includes(text(options.search)),
      );
    if (options.artistId)
      items = items.filter((item) => item.artistId === options.artistId);
    if (options.genre)
      items = items.filter((item) => item.genre === options.genre);
    if (options.fromYear !== undefined)
      items = items.filter((item) => (item.year ?? 0) >= options.fromYear!);
    if (options.toYear !== undefined)
      items = items.filter((item) => (item.year ?? 0) <= options.toYear!);
    if (options.starredOnly)
      items = items.filter((item) => Boolean(item.starred));
    if (options.sortBy === "random") items.sort(() => Math.random() - 0.5);
    else {
      const field = options.sortBy ?? "name";
      items.sort(
        (a, b) =>
          text(a[field as keyof NativeAlbum]).localeCompare(
            text(b[field as keyof NativeAlbum]),
          ) * (options.sortOrder === "desc" ? -1 : 1),
      );
    }
    return paginate(items, options);
  }

  getAlbum({ id }: { id: string }) {
    const album = this.store.get("albums").find((item) => item.id === id);
    return album
      ? {
          ...album,
          song: this.store.get("songs").filter((song) => song.albumId === id),
        }
      : null;
  }

  getSongs(options: PaginatedQuery & SongFilter) {
    let items = [...this.store.get("songs")];
    if (options.search)
      items = items.filter((item) =>
        [item.title, item.artist, item.album].some((value) =>
          text(value).includes(text(options.search)),
        ),
      );
    if (options.albumId)
      items = items.filter((item) => item.albumId === options.albumId);
    if (options.artistId)
      items = items.filter((item) => item.artistId === options.artistId);
    if (options.genre)
      items = items.filter((item) => item.genre === options.genre);
    if (options.starredOnly)
      items = items.filter((item) => Boolean(item.starred));
    const field = options.sortBy ?? "title";
    items.sort(
      (a, b) =>
        text(a[field as keyof NativeSong]).localeCompare(
          text(b[field as keyof NativeSong]),
        ) * (options.sortOrder === "desc" ? -1 : 1),
    );
    return paginate(items, options);
  }

  getPlaylists(options: PaginatedQuery = { limit: 10_000, offset: 0 }) {
    return paginate(this.store.get("playlists"), options);
  }

  async getPlaylist({ id }: { id: string }) {
    const cached = this.store.get("playlistDetails")[id];
    if (cached) return cached;
    const response = await this.bridge.request({
      path: "/getPlaylist.view",
      query: { id },
    });
    const playlist = response.data.playlist as
      | NativePlaylistWithEntries
      | undefined;
    if (!playlist) return null;
    this.store.set(`playlistDetails.${id}`, playlist);
    return playlist;
  }

  getGenres() {
    return { items: this.store.get("genres") };
  }

  getFavorites(
    options: PaginatedQuery & { type: "songs" | "albums" | "artists" },
  ) {
    const source = this.store
      .get(options.type)
      .filter((item) => Boolean(item.starred));
    return paginate(source, options);
  }

  getSearch(options: {
    query: string;
    artistCount?: number;
    albumCount?: number;
    songCount?: number;
  }): NativeSearchResult {
    const query = text(options.query);
    return {
      artists: this.store
        .get("artists")
        .filter((item) => text(item.name).includes(query))
        .slice(0, options.artistCount ?? 20),
      albums: this.store
        .get("albums")
        .filter(
          (item) =>
            text(item.name).includes(query) ||
            text(item.artist).includes(query),
        )
        .slice(0, options.albumCount ?? 20),
      songs: this.store
        .get("songs")
        .filter((item) =>
          [item.title, item.artist, item.album].some((value) =>
            text(value).includes(query),
          ),
        )
        .slice(0, options.songCount ?? 20),
    };
  }

  getLyrics({ songId }: { songId: string }) {
    return this.store.get("lyrics")[songId] ?? null;
  }

  storeLyrics(options: {
    songId: string;
    content: string;
    synced: boolean;
  }): void {
    const now = Date.now();
    this.store.set(`lyrics.${options.songId}`, {
      ...options,
      cachedAt: now,
      lastAccessedAt: now,
    });
  }

  getCacheStats() {
    return {
      totalItems: this.store.get("songs").length,
      totalSizeBytes: 0,
      audioCount: 0,
      coverCount: 0,
    };
  }

  isDataAvailableOffline() {
    const lastSyncedAt = this.store.get("lastSyncedAt") ?? null;
    return { available: this.store.get("songs").length > 0, lastSyncedAt };
  }

  async storeCoverImage(options: {
    coverArtId: string;
    dataBase64: string;
    contentType: string;
    coverSize: string;
  }) {
    return {
      file: await this.writeCover(
        options.coverArtId,
        Buffer.from(options.dataBase64, "base64"),
        options.contentType,
        options.coverSize,
      ),
    };
  }

  async resolveCoverImage({ coverArtId }: { coverArtId: string }) {
    const meta = this.store.get("coverFiles")[coverArtId];
    if (!meta) return { file: null };
    const path = join(this.coverDirectory(), meta.fileName);
    try {
      const info = await stat(path);
      return {
        file: {
          coverArtId,
          uri: `aonsoku-media://cached?id=${encodeURIComponent(coverArtId)}`,
          contentType: meta.contentType,
          sizeBytes: info.size,
          coverSize: meta.coverSize,
        },
      };
    } catch {
      return { file: null };
    }
  }

  async getCoverImageSize({ coverArtId }: { coverArtId: string }) {
    const resolved = await this.resolveCoverImage({ coverArtId });
    return {
      sizeBytes: resolved.file?.sizeBytes ?? null,
      coverSize: resolved.file?.coverSize ?? null,
    };
  }

  async deleteCoverImage({ coverArtId }: { coverArtId: string }) {
    const files = { ...this.store.get("coverFiles") };
    const meta = files[coverArtId];
    if (!meta) return { deleted: false };
    await rm(join(this.coverDirectory(), meta.fileName), { force: true });
    delete files[coverArtId];
    this.store.set("coverFiles", files);
    return { deleted: true };
  }

  async clearCoverImages() {
    const directory = this.coverDirectory();
    let deletedCount = 0;
    try {
      const files = await readdir(directory);
      deletedCount = files.length;
      await Promise.all(
        files.map((file) => rm(join(directory, file), { force: true })),
      );
    } catch {}
    this.store.set("coverFiles", {});
    return { deletedCount };
  }

  async downloadCoverImage({
    coverArtId,
    size,
  }: {
    coverArtId: string;
    size: string;
  }) {
    const response = await this.bridge.downloadBinary("/getCoverArt.view", {
      id: coverArtId,
      size,
    });
    return {
      file: await this.writeCover(
        coverArtId,
        response.data,
        response.contentType,
        size,
      ),
    };
  }

  async downloadAvatar({ username, size }: { username: string; size: string }) {
    const response = await this.bridge.downloadBinary("/getAvatar.view", {
      username,
      size,
    });
    return {
      file: await this.writeCover(
        username,
        response.data,
        response.contentType,
        size,
      ),
    };
  }

  private coverDirectory(): string {
    return join(app.getPath("userData"), "CoverCache");
  }

  private async writeCover(
    coverArtId: string,
    data: Buffer,
    contentType: string,
    coverSize: string,
  ) {
    const directory = this.coverDirectory();
    await mkdir(directory, { recursive: true });
    const extension = contentType.includes("png")
      ? "png"
      : contentType.includes("webp")
        ? "webp"
        : "jpg";
    const fileName = `${Buffer.from(coverArtId).toString("base64url")}.${extension}`;
    const path = join(directory, fileName);
    await writeFile(path, data);
    this.store.set("coverFiles", {
      ...this.store.get("coverFiles"),
      [coverArtId]: { fileName, contentType, coverSize },
    });
    return {
      coverArtId,
      uri: `aonsoku-media://cached?id=${encodeURIComponent(coverArtId)}`,
      contentType,
      sizeBytes: data.byteLength,
      coverSize,
    };
  }

  async readCover(
    coverArtId: string,
  ): Promise<{ data: Buffer; contentType: string } | null> {
    const meta = this.store.get("coverFiles")[coverArtId];
    if (!meta) return null;
    try {
      return {
        data: await readFile(join(this.coverDirectory(), meta.fileName)),
        contentType: meta.contentType,
      };
    } catch {
      return null;
    }
  }

  /**
   * Read a cached cover/avatar together with its stored `coverSize`.
   *
   * Used by the `aonsoku-media://` image proxy to serve a disk-cached image
   * without re-hitting the server. The caller compares `coverSize` against
   * the requested size and only reverts to the network when the cached copy
   * is too small, mirroring `isCoverSizeAtLeast` on the renderer side.
   */
  async readCoverWithMeta(coverArtId: string): Promise<{
    data: Buffer;
    contentType: string;
    coverSize: string;
  } | null> {
    const meta = this.store.get("coverFiles")[coverArtId];
    if (!meta) return null;
    try {
      return {
        data: await readFile(join(this.coverDirectory(), meta.fileName)),
        contentType: meta.contentType,
        coverSize: meta.coverSize,
      };
    } catch {
      return null;
    }
  }
}
