import { randomUUID } from "node:crypto";
import { realpathSync, statSync } from "node:fs";
import {
  mkdir,
  readdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { join, sep } from "node:path";
import { pathToFileURL } from "node:url";
import type {
  AlbumFilter,
  ArtistFilter,
  NativeAlbum,
  NativeArtist,
  NativeCachedCoverImageFile,
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

function normalizedCoverSize(size: string | undefined): number {
  const parsed = Number(size);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

interface CoverGeneration {
  cache: number;
  entry: number;
}

interface CoverDownloadTask {
  requestedSize: number;
  promise: Promise<NativeCachedCoverImageFile | null>;
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
  private readonly coverDownloads = new Map<string, CoverDownloadTask>();
  private readonly coverGenerations = new Map<string, number>();
  private coverPublicationTail = Promise.resolve();
  private coverCacheGeneration = 0;

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

  async syncAll(options?: {
    includeCoverArt?: boolean;
    includeFullSongs?: boolean;
    coverArtConcurrency?: number;
    useAlbumCoverForSongs?: boolean;
  }): Promise<void> {
    await this.sync(false, options?.includeFullSongs ?? false, options);
  }

  async syncIncremental(options?: {
    includeCoverArt?: boolean;
    includeFullSongs?: boolean;
    coverArtConcurrency?: number;
    useAlbumCoverForSongs?: boolean;
  }): Promise<void> {
    await this.sync(true, false, options);
  }

  private updateSyncState(state: Partial<NativeSyncState>): void {
    this.syncState = { ...this.syncState, ...state };
    this.emit("syncStateChanged", this.syncState);
  }

  private async sync(
    _incremental: boolean,
    includeFullSongs: boolean,
    options?: {
      includeCoverArt?: boolean;
      coverArtConcurrency?: number;
      useAlbumCoverForSongs?: boolean;
    },
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
        if (options?.includeCoverArt) {
          await this.syncCoverArt({
            artists: this.store.get("artists"),
            albums,
            playlists,
            songs: this.store.get("songs"),
            concurrency: options.coverArtConcurrency,
            useAlbumCoverForSongs: options.useAlbumCoverForSongs,
          });
          if (this.cancelled) return;
        }
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
      if (options?.includeCoverArt) {
        await this.syncCoverArt({
          artists: this.store.get("artists"),
          albums,
          playlists,
          songs: mergedSongs,
          concurrency: options.coverArtConcurrency,
          useAlbumCoverForSongs: options.useAlbumCoverForSongs,
        });
        if (this.cancelled) return;
      }
      this.updateSyncState({ phase: "done", progress: 1 });
    } catch (error) {
      this.updateSyncState({ phase: "error" });
      throw error;
    } finally {
      this.updateSyncState({ isSyncing: false });
    }
  }

  private async syncCoverArt({
    artists,
    albums,
    playlists,
    songs,
    concurrency = 4,
    useAlbumCoverForSongs = false,
  }: {
    artists: NativeArtist[];
    albums: NativeAlbum[];
    playlists: NativePlaylist[];
    songs: NativeSong[];
    concurrency?: number;
    useAlbumCoverForSongs?: boolean;
  }): Promise<void> {
    const coverArtIds = new Set<string>();
    const isLms = this.bridge.getCredentials()?.serverType === "lms";

    for (const artist of artists) {
      if (artist.coverArt) coverArtIds.add(artist.coverArt);
      // Album details expose artist.id, while artist grids expose coverArt.
      // Keep both keys available so either surface can resolve offline.
      if (!isLms && artist.id) coverArtIds.add(artist.id);
    }
    for (const album of albums) {
      if (album.coverArt) coverArtIds.add(album.coverArt);
      if (useAlbumCoverForSongs && album.id) coverArtIds.add(album.id);
    }
    for (const playlist of playlists) {
      if (playlist.coverArt) coverArtIds.add(playlist.coverArt);
    }
    if (!useAlbumCoverForSongs) {
      for (const song of songs) {
        if (song.coverArt) coverArtIds.add(song.coverArt);
      }
    }

    const queue = Array.from(coverArtIds);
    const total = queue.length;
    this.updateSyncState({
      phase: "coverArt",
      progress: total === 0 ? 1 : 0,
      processedItems: 0,
      totalItems: total,
    });
    if (total === 0) return;

    const parsedConcurrency = Number(concurrency);
    const workerCount = Math.min(
      total,
      Number.isFinite(parsedConcurrency)
        ? Math.max(1, Math.min(8, Math.trunc(parsedConcurrency)))
        : 4,
    );
    let nextIndex = 0;
    let processed = 0;

    const worker = async () => {
      while (!this.cancelled) {
        const index = nextIndex++;
        if (index >= total) return;
        const coverArtId = queue[index];
        try {
          const existing = await this.getCoverImageSize({ coverArtId });
          if (!existing.coverSize || Number(existing.coverSize) < 700) {
            await this.downloadCoverImage({ coverArtId, size: "700" });
          }
        } catch (error) {
          console.warn(
            `[desktopNativeData] failed to cache cover ${coverArtId}:`,
            error,
          );
        } finally {
          processed++;
          this.updateSyncState({
            processedItems: processed,
            progress: processed / total,
          });
        }
      }
    };

    await Promise.all(Array.from({ length: workerCount }, () => worker()));
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
    const generation = this.coverGeneration(options.coverArtId);
    return {
      file: await this.writeCover(
        options.coverArtId,
        Buffer.from(options.dataBase64, "base64"),
        options.contentType,
        options.coverSize,
        generation,
      ),
    };
  }

  async resolveCoverImage({ coverArtId }: { coverArtId: string }) {
    let meta = this.store.get("coverFiles")[coverArtId];
    for (let attempt = 0; meta && attempt < 2; attempt++) {
      try {
        const info = await stat(join(this.coverDirectory(), meta.fileName));
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
        const current = this.store.get("coverFiles")[coverArtId];
        if (!current || current.fileName === meta.fileName) break;
        meta = current;
      }
    }
    return { file: null };
  }

  resolveCoverFileUri(coverArtId: string): string | undefined {
    const meta = this.store.get("coverFiles")[coverArtId];
    if (!meta) return undefined;
    try {
      const directory = realpathSync(this.coverDirectory());
      const path = realpathSync(join(directory, meta.fileName));
      if (!path.startsWith(`${directory}${sep}`) || !statSync(path).isFile()) {
        return undefined;
      }
      return pathToFileURL(path).toString();
    } catch {
      return undefined;
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
    this.coverGenerations.set(
      coverArtId,
      (this.coverGenerations.get(coverArtId) ?? 0) + 1,
    );
    return this.withCoverPublicationLock(async () => {
      const files = { ...this.store.get("coverFiles") };
      const meta = files[coverArtId];
      if (!meta) return { deleted: false };
      await rm(join(this.coverDirectory(), meta.fileName), { force: true });
      delete files[coverArtId];
      this.store.set("coverFiles", files);
      return { deleted: true };
    });
  }

  async clearCoverImages() {
    // Invalidate every task that captured the previous cache generation before
    // entering the publication queue. New writes line up behind this clear.
    this.coverCacheGeneration++;
    return this.withCoverPublicationLock(async () => {
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
    });
  }

  async downloadCoverImage({
    coverArtId,
    size,
  }: {
    coverArtId: string;
    size: string;
  }) {
    return {
      file: await this.downloadAndStoreCover("cover", coverArtId, size),
    };
  }

  async downloadAvatar({ username, size }: { username: string; size: string }) {
    return {
      file: await this.downloadAndStoreCover("avatar", username, size),
    };
  }

  private async downloadAndStoreCover(
    kind: "cover" | "avatar",
    coverArtId: string,
    size: string,
  ) {
    const requestedSize = normalizedCoverSize(size);
    const taskKey = `${kind}:${coverArtId}`;

    while (true) {
      const cached = await this.resolveCoverImage({ coverArtId });
      if (
        cached.file &&
        normalizedCoverSize(cached.file.coverSize) >= requestedSize
      ) {
        return cached.file;
      }

      const current = this.coverDownloads.get(taskKey);
      if (current) {
        try {
          await current.promise;
        } catch (error) {
          // A larger request queued behind a failed smaller request gets one
          // chance to become the next owner. Equal/smaller callers observe the
          // shared failure; a later request can retry after `finally` cleanup.
          if (current.requestedSize >= requestedSize) throw error;
        }
        continue;
      }

      const generation = this.coverGeneration(coverArtId);
      const promise: CoverDownloadTask["promise"] = this.fetchAndStoreCover(
        kind,
        coverArtId,
        size,
        generation,
      ).finally(() => {
        if (this.coverDownloads.get(taskKey)?.promise === promise) {
          this.coverDownloads.delete(taskKey);
        }
      });
      this.coverDownloads.set(taskKey, { requestedSize, promise });
      return promise;
    }
  }

  private async fetchAndStoreCover(
    kind: "cover" | "avatar",
    coverArtId: string,
    size: string,
    generation: CoverGeneration,
  ) {
    const response = await this.bridge.downloadBinary(
      kind === "cover" ? "/getCoverArt.view" : "/getAvatar.view",
      {
        [kind === "cover" ? "id" : "username"]: coverArtId,
        ...(size ? { size } : {}),
      },
    );
    return this.writeCover(
      coverArtId,
      response.data,
      response.contentType,
      size,
      generation,
    );
  }

  private coverDirectory(): string {
    return join(app.getPath("userData"), "CoverCache");
  }

  private async writeCover(
    coverArtId: string,
    data: Buffer,
    contentType: string,
    coverSize: string,
    generation: CoverGeneration,
  ) {
    return this.withCoverPublicationLock(async () => {
      if (!this.isCurrentCoverGeneration(coverArtId, generation)) return null;

      const existing = await this.resolveCoverImage({ coverArtId });
      if (
        existing.file &&
        normalizedCoverSize(existing.file.coverSize) >
          normalizedCoverSize(coverSize)
      ) {
        return existing.file;
      }

      const directory = this.coverDirectory();
      await mkdir(directory, { recursive: true });
      const extension = contentType.includes("png")
        ? "png"
        : contentType.includes("webp")
          ? "webp"
          : "jpg";
      const encodedId = Buffer.from(coverArtId).toString("base64url");
      const publicationId = randomUUID();
      const fileName = `${encodedId}.${publicationId}.${extension}`;
      const tempPath = join(directory, `${fileName}.tmp`);
      const path = join(directory, fileName);

      try {
        await writeFile(tempPath, data);
        await rename(tempPath, path);
        if (!this.isCurrentCoverGeneration(coverArtId, generation)) {
          await rm(path, { force: true });
          return null;
        }

        // Recheck under the publication lock immediately before publication.
        // This is the final guard against a smaller completion replacing a
        // larger file written through another entry point.
        const files = this.store.get("coverFiles");
        const current = files[coverArtId];
        if (
          current &&
          normalizedCoverSize(current.coverSize) >
            normalizedCoverSize(coverSize)
        ) {
          await rm(path, { force: true });
          return (await this.resolveCoverImage({ coverArtId })).file;
        }

        this.store.set("coverFiles", {
          ...files,
          [coverArtId]: { fileName, contentType, coverSize },
        });
        if (current?.fileName && current.fileName !== fileName) {
          await rm(join(directory, current.fileName), { force: true }).catch(
            () => {},
          );
        }
        return {
          coverArtId,
          uri: `aonsoku-media://cached?id=${encodeURIComponent(coverArtId)}`,
          contentType,
          sizeBytes: data.byteLength,
          coverSize,
        };
      } finally {
        await rm(tempPath, { force: true }).catch(() => {});
      }
    });
  }

  private coverGeneration(coverArtId: string): CoverGeneration {
    return {
      cache: this.coverCacheGeneration,
      entry: this.coverGenerations.get(coverArtId) ?? 0,
    };
  }

  private isCurrentCoverGeneration(
    coverArtId: string,
    generation: CoverGeneration,
  ): boolean {
    return (
      generation.cache === this.coverCacheGeneration &&
      generation.entry === (this.coverGenerations.get(coverArtId) ?? 0)
    );
  }

  private async withCoverPublicationLock<T>(
    operation: () => Promise<T>,
  ): Promise<T> {
    const previous = this.coverPublicationTail;
    let release = () => {};
    const lock = new Promise<void>((resolve) => {
      release = resolve;
    });
    this.coverPublicationTail = lock;
    await previous;
    try {
      return await operation();
    } finally {
      release();
      if (this.coverPublicationTail === lock) {
        this.coverPublicationTail = Promise.resolve();
      }
    }
  }

  async readCover(
    coverArtId: string,
  ): Promise<{ data: Buffer; contentType: string } | null> {
    const stored = await this.readStoredCover(coverArtId);
    return stored
      ? { data: stored.data, contentType: stored.meta.contentType }
      : null;
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
    const stored = await this.readStoredCover(coverArtId);
    return stored
      ? {
          data: stored.data,
          contentType: stored.meta.contentType,
          coverSize: stored.meta.coverSize,
        }
      : null;
  }

  private async readStoredCover(coverArtId: string) {
    let meta = this.store.get("coverFiles")[coverArtId];
    for (let attempt = 0; meta && attempt < 2; attempt++) {
      try {
        return {
          data: await readFile(join(this.coverDirectory(), meta.fileName)),
          meta,
        };
      } catch {
        // Atomic replacement publishes a new filename before removing the old
        // one. A reader that captured the old metadata can lose that race; if
        // publication advanced, retry once against the current filename.
        const current = this.store.get("coverFiles")[coverArtId];
        if (!current || current.fileName === meta.fileName) break;
        meta = current;
      }
    }
    return null;
  }
}
