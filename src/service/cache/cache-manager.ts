import { Capacitor } from "@capacitor/core";
import { getAvatarUrl, getCoverArtUrl } from "@/api/httpClient";

function convertFileSrc(uri: string): string {
  if (typeof uri !== "string" || !uri.startsWith("file:")) {
    return Capacitor.convertFileSrc(uri);
  }
  const serverUrl = Capacitor.getServerUrl?.() ?? "";
  if (!serverUrl) return Capacitor.convertFileSrc(uri);

  // Handle all file: URI variants produced by the native layer:
  //   "file:///absolute/path"  – RFC 8089 (iOS, Capacitor's own convertFileSrc)
  //   "file:/absolute/path"    – Java File.toURI() (Android native plugin)
  //   "file://relative/path"   – not used, handled for safety
  // Strip the "file:" scheme, then normalize leading slashes to "/".
  let filePath = uri.slice(5);
  while (filePath.startsWith("//")) {
    filePath = filePath.slice(1);
  }
  if (!filePath.startsWith("/")) {
    filePath = "/" + filePath;
  }

  return `${serverUrl}/_capacitor_file_${filePath}`;
}
import { asyncPool } from "@/service/cache/concurrency";
import { subsonic } from "@/service/subsonic";
import { useCacheStore } from "@/store/cache.store";
import {
  getCacheIndexActions,
  getCacheIndexItems,
  isAudioCached,
  isAvatarCached,
  isCoverCached,
  useCacheIndexStore,
} from "@/store/cache-index.store";
import { libraryDb } from "@/store/library-db";
import { usePlayerStore } from "@/store/player.store";
import { CachedItemMeta, CacheMetaSource, Priority } from "@/types/cache";
import { getSongCoverArtId } from "@/utils/coverArt";
import { audioCacheService } from "./audio-cache-worker-adapter";
import { resolveCachedAudioSource } from "./audio-source";
import {
  albumKey,
  audioKey,
  avatarKey,
  COVER_PREFIX,
  coverKey,
  isOldCoverKey,
  playlistKey,
  songIdFromKey,
} from "./cache-keys";
import { cacheStorage } from "./cache-storage";
import { computeEvictionPlan } from "./eviction";
import {
  clearNativeAudioFilesIfAvailable,
  evictNativeAudioFileIfAvailable,
} from "./native-cache-adapter";
import {
  getNativeImageCacheAdapter,
  isNativeImageCacheAdapterAvailable,
} from "./native-image-cache-adapter";
import {
  bulkDeleteCacheMeta,
  deleteCacheMeta,
  persistCacheMeta,
} from "./persist-meta";
import { syncService } from "./sync-worker-adapter";

export { buildAudioUrl } from "./audio-url-resolver";

export interface CachedItemDetail {
  key: string;
  id: string;
  type: "audio" | "cover" | "album" | "playlist";
  source: CacheMetaSource;
  name: string;
  subtitle?: string;
  sizeBytes: number;
  cachedAt: number;
  lastAccessedAt: number;
  coverSize?: string;
  removedFromServer?: boolean;
}

// ═══════════════════════════════════════════════════════════════════
//  Stats helper (extracted to avoid circular deps)
// ═══════════════════════════════════════════════════════════════════

function refreshCacheStats(): void {
  const items = getCacheIndexItems();
  let audioSize = 0;
  let coverSize = 0;
  let audioCount = 0;
  let coverCount = 0;

  for (const meta of Object.values(items)) {
    if (meta.type === "audio") {
      audioSize += meta.sizeBytes;
      audioCount++;
    } else {
      coverSize += meta.sizeBytes;
      coverCount++;
    }
  }

  useCacheStore.getState().actions.updateCacheStats({
    audioSize,
    coverSize,
    audioCount,
    coverCount,
  });
}

function isCoverSizeAtLeast(
  cachedSize: string | undefined,
  requestedSize: string | undefined,
): boolean {
  if (!requestedSize) return true;

  const requested = Number(requestedSize);
  if (!Number.isFinite(requested) || requested <= 0) return true;

  const cached = Number(cachedSize);
  if (!Number.isFinite(cached) || cached <= 0) return true;

  return cached >= requested;
}

class AsyncLimiter {
  private active = 0;
  private queue: Array<() => void> = [];

  constructor(private readonly limit: number) {}

  run<T>(task: () => Promise<T>): Promise<T> {
    return new Promise((resolve, reject) => {
      const start = () => {
        this.active++;
        task()
          .then(resolve, reject)
          .finally(() => {
            this.active--;
            this.queue.shift()?.();
          });
      };

      if (this.active < this.limit) {
        start();
      } else {
        this.queue.push(start);
      }
    });
  }
}

// ═══════════════════════════════════════════════════════════════════
//  CacheManager — strategy / orchestration layer (main thread only)
// ═══════════════════════════════════════════════════════════════════

class CacheManager {
  private statsTimer: ReturnType<typeof setTimeout> | null = null;
  private cacheCoverInflight = new Map<string, Promise<void>>();
  private nativeCoverUrlCache = new Map<
    string,
    { url: string; coverSize?: string }
  >();
  private nativeCoverUrlInflight = new Map<string, Promise<string | null>>();
  private coverDownloadLimiter = new AsyncLimiter(4);

  isDownloadQueued(songId: string): boolean {
    return (
      audioCacheService.isQueued(songId) || audioCacheService.isInFlight(songId)
    );
  }

  async cacheSong(songId: string): Promise<void> {
    if (isAudioCached(songId)) return;
    getCacheIndexActions().setDownloadProgress(songId, 0);
    return audioCacheService.cacheSong({
      songId,
      priority: Priority.Explicit,
      source: "explicit",
    });
  }

  /**
   * Download `songId` and tag it as a smart-download, carrying the
   * rule names that triggered the decision. Used by the
   * SmartDownloadEngine (P5). If the song is already cached as
   * `"explicit"` we leave it alone — the user decided manually, we
   * don't demote them. If it's `"lru"` we upgrade the entry to
   * `"smart"` so future LRU pressure doesn't evict it.
   */
  async cacheSmartSong(songId: string, triggers: string[]): Promise<void> {
    const key = audioKey(songId);
    const existing = getCacheIndexItems()[key];

    if (existing) {
      if (existing.source === "explicit") return; // user already owns it
      if (existing.source === "smart") {
        // Refresh triggers so "why is this cached?" stays accurate.
        const updated = { ...existing, triggers, lastAccessedAt: Date.now() };
        getCacheIndexActions().addItem(key, updated);
        persistCacheMeta(key, { key, ...updated });
        return;
      }
      if (existing.source === "lru") {
        const updated = {
          ...existing,
          source: "smart" as const,
          triggers,
          lastAccessedAt: Date.now(),
        };

        getCacheIndexActions().addItem(key, updated);
        persistCacheMeta(key, { key, ...updated });
        return;
      }
    }

    return audioCacheService.cacheSong({
      songId,
      priority: Priority.Background,
      source: "smart",
      triggers,
    });
  }

  /**
   * Fetch and store structured lyrics for a song in `libraryDb.lyrics`.
   * Called after `cacheSong` so explicit/smart downloads bring their
   * lyrics along for offline playback. Silently returns when the
   * server doesn't have lyrics for this song or when they are already
   * cached.
   */
  async cacheLyrics(songId: string): Promise<void> {
    const existing = await libraryDb.lyrics.get(songId);
    if (existing) return;

    const structured = await subsonic.lyrics.getStructuredLyrics(songId);
    if (!structured || structured.length === 0) return;

    // Pick the first (usually the source-language) entry and store its
    // lines as a JSON blob for simplicity. `synced` is true iff at
    // least one line carries a `start` timestamp.
    const primary = structured[0];
    const synced = primary.line.some((l) => typeof l.start === "number");
    const content = JSON.stringify(structured);
    const now = Date.now();

    await libraryDb.lyrics.put({
      songId,
      content,
      synced,
      cachedAt: now,
      lastAccessedAt: now,
    });
  }

  /**
   * Resolve a cached audio blob to a local URL the <audio> element can
   * play. Returns `null` when the song is not in the cache.
   *
   * **Callers must call `URL.revokeObjectURL()` on the returned string
   * when they are done with it (e.g. on song change or unmount) to
   * avoid leaking memory.**
   */
  async getCachedAudioUrl(songId: string): Promise<string | null> {
    const source = await resolveCachedAudioSource(songId);
    if (source) return source.url;

    const key = audioKey(songId);
    if (getCacheIndexItems()[key]) {
      getCacheIndexActions().removeItem(key);
      await deleteCacheMeta(key);
    }

    return null;
  }

  async cacheCover(coverArtId: string, size = "700"): Promise<void> {
    const key = coverKey(coverArtId);
    const inflight = this.cacheCoverInflight.get(key);
    if (inflight) return inflight;

    const p = this.cacheCoverImpl(coverArtId, size).finally(() => {
      this.cacheCoverInflight.delete(key);
    });
    this.cacheCoverInflight.set(key, p);
    return p;
  }

  private async cacheCoverImpl(
    coverArtId: string,
    size = "700",
  ): Promise<void> {
    const key = coverKey(coverArtId);

    if (isNativeImageCacheAdapterAvailable()) {
      const adapter = getNativeImageCacheAdapter();
      const existing = await adapter.getCoverImageSize(coverArtId);
      if (existing.coverSize && Number(existing.coverSize) >= Number(size)) {
        return;
      }

      const result = await this.coverDownloadLimiter.run(() =>
        adapter.downloadCoverImage(coverArtId, size),
      );
      if (!result) return;
      this.rememberNativeCoverUrl(coverArtId, convertFileSrc(result.uri), size);

      const meta: CachedItemMeta = {
        id: coverArtId,
        type: "cover",
        source: "explicit",
        coverSize: size,
        sizeBytes: result.sizeBytes ?? 0,
        cachedAt: Date.now(),
        lastAccessedAt: Date.now(),
      };

      getCacheIndexActions().addItem(key, meta);
      this.scheduleStatsRefresh();
      persistCacheMeta(key, { key, ...meta });
      return;
    }

    const items = getCacheIndexItems();
    const existing = items[key];
    const existingSize = Number(existing?.coverSize ?? "0");
    const requestedSize = Number(size);

    if (existing && existingSize >= requestedSize) return;

    const url = getCoverArtUrl(coverArtId, "album", size);
    if (url.startsWith("/default_")) return;

    const blob = await this.coverDownloadLimiter.run(async () => {
      const response = await fetch(url);
      if (!response.ok) return null;
      return response.blob();
    });
    if (!blob) return;

    if (existing) {
      await cacheStorage.delete(key);
    }

    await cacheStorage.put(key, blob, blob.type || "image/jpeg");

    const meta: CachedItemMeta = {
      id: coverArtId,
      type: "cover",
      source: existing?.source ?? "explicit",
      coverSize: size,
      sizeBytes: blob.size,
      cachedAt: existing?.cachedAt ?? Date.now(),
      lastAccessedAt: Date.now(),
    };

    getCacheIndexActions().addItem(key, meta);
    this.scheduleStatsRefresh();
    persistCacheMeta(key, { key, ...meta });
  }

  /**
   * Resolve a cached cover art blob to a local URL for <img> elements.
   * Returns `null` when the cover is not in the cache.
   *
   * **Callers must call `URL.revokeObjectURL()` on the returned string
   * when they are done with it to avoid leaking memory.**
   */
  async getCachedCoverUrl(
    coverArtId: string,
    requestedSize?: string,
  ): Promise<string | null> {
    const key = coverKey(coverArtId);

    if (isNativeImageCacheAdapterAvailable()) {
      const cachedUrl = this.nativeCoverUrlCache.get(coverArtId);
      if (
        cachedUrl &&
        isCoverSizeAtLeast(cachedUrl.coverSize, requestedSize)
      ) {
        getCacheIndexActions().touchItem(key);
        return cachedUrl.url;
      }

      const inflight = this.nativeCoverUrlInflight.get(coverArtId);
      if (inflight) return inflight;

      const resolve = this.resolveNativeCachedCoverUrl(
        coverArtId,
        key,
        requestedSize,
      ).finally(() => {
          this.nativeCoverUrlInflight.delete(coverArtId);
        });
      this.nativeCoverUrlInflight.set(coverArtId, resolve);
      return resolve;
    }

    // Fast path: when the index is loaded and the key is absent, skip
    // the async Cache API lookup.
    const { loaded } = useCacheIndexStore.getState();
    if (loaded && !isCoverCached(coverArtId)) return null;
    const indexedCoverSize = getCacheIndexItems()[key]?.coverSize;
    if (
      loaded &&
      isCoverCached(coverArtId) &&
      !isCoverSizeAtLeast(indexedCoverSize, requestedSize)
    ) {
      return null;
    }

    // Slow path: read Cache API directly for the startup case where
    // the in-memory index has not finished loading from IDB yet.
    const blob = await cacheStorage.get(key);
    if (!blob) {
      if (isCoverCached(coverArtId)) {
        getCacheIndexActions().removeItem(key);
      }
      return null;
    }

    // Self-heal: if the blob exists but the index missed it, try to
    // recover the original metadata from Dexie cacheMeta.
    if (!isCoverCached(coverArtId)) {
      const existingRow = await libraryDb.cacheMeta.get(key);
      if (existingRow) {
        getCacheIndexActions().addItem(key, {
          id: existingRow.id,
          type: existingRow.type,
          source: existingRow.source,
          coverSize: (existingRow as Record<string, unknown>).coverSize as
            | string
            | undefined,
          sizeBytes: existingRow.sizeBytes,
          cachedAt: existingRow.cachedAt,
          lastAccessedAt: Date.now(),
          removedFromServer: existingRow.removedFromServer,
        });
      } else {
        const syntheticMeta = {
          id: coverArtId,
          type: "cover" as const,
          source: "explicit" as const,
          coverSize: "700",
          sizeBytes: blob.size,
          cachedAt: Date.now(),
          lastAccessedAt: Date.now(),
        };
        getCacheIndexActions().addItem(key, syntheticMeta);
        persistCacheMeta(key, { key, ...syntheticMeta });
      }
    } else {
      getCacheIndexActions().touchItem(key);
    }

    return URL.createObjectURL(blob);
  }

  private async resolveNativeCachedCoverUrl(
    coverArtId: string,
    key: string,
    requestedSize?: string,
  ): Promise<string | null> {
    const adapter = getNativeImageCacheAdapter();
    const result = await adapter.resolveCoverImage(coverArtId);
    if (!result) {
      this.nativeCoverUrlCache.delete(coverArtId);
      if (isCoverCached(coverArtId)) {
        getCacheIndexActions().removeItem(key);
      }
      return null;
    }

    const coverSize = result.coverSize ?? getCacheIndexItems()[key]?.coverSize;
    if (!isCoverSizeAtLeast(coverSize, requestedSize)) {
      return null;
    }

    if (!isCoverCached(coverArtId)) {
      const existingRow = await libraryDb.cacheMeta.get(key);
      if (existingRow) {
        getCacheIndexActions().addItem(key, {
          id: existingRow.id,
          type: existingRow.type,
          source: existingRow.source,
          coverSize: (existingRow as Record<string, unknown>).coverSize as
            | string
            | undefined,
          sizeBytes: existingRow.sizeBytes,
          cachedAt: existingRow.cachedAt,
          lastAccessedAt: Date.now(),
          removedFromServer: existingRow.removedFromServer,
        });
      } else {
        const syntheticMeta = {
          id: coverArtId,
          type: "cover" as const,
          source: "explicit" as const,
          coverSize: result.coverSize ?? "700",
          sizeBytes: result.sizeBytes ?? 0,
          cachedAt: Date.now(),
          lastAccessedAt: Date.now(),
        };
        getCacheIndexActions().addItem(key, syntheticMeta);
        persistCacheMeta(key, { key, ...syntheticMeta });
      }
    } else {
      getCacheIndexActions().touchItem(key);
    }

    return this.rememberNativeCoverUrl(
      coverArtId,
      convertFileSrc(result.uri),
      coverSize,
    );
  }

  private rememberNativeCoverUrl(
    coverArtId: string,
    url: string,
    coverSize?: string,
  ): string {
    this.nativeCoverUrlCache.delete(coverArtId);
    this.nativeCoverUrlCache.set(coverArtId, { url, coverSize });

    if (this.nativeCoverUrlCache.size > 500) {
      const oldest = this.nativeCoverUrlCache.keys().next().value;
      if (oldest) this.nativeCoverUrlCache.delete(oldest);
    }

    return url;
  }

  async cacheAvatar(username: string, size = "150"): Promise<void> {
    const key = avatarKey(username);
    const items = getCacheIndexItems();
    const existing = items[key];

    if (existing) return;

    if (isNativeImageCacheAdapterAvailable()) {
      const adapter = getNativeImageCacheAdapter();
      const result = await adapter.downloadAvatar(username, size);
      if (!result) return;

      const meta: CachedItemMeta = {
        id: username,
        type: "cover",
        source: "explicit",
        coverSize: size,
        sizeBytes: result.sizeBytes ?? 0,
        cachedAt: Date.now(),
        lastAccessedAt: Date.now(),
      };

      getCacheIndexActions().addItem(key, meta);
      this.scheduleStatsRefresh();
      persistCacheMeta(key, { key, ...meta });
      return;
    }

    const url = getAvatarUrl(username, size);
    const response = await fetch(url);
    if (!response.ok) return;

    const blob = await response.blob();

    await cacheStorage.put(key, blob, blob.type || "image/jpeg");

    const meta: CachedItemMeta = {
      id: username,
      type: "cover",
      source: "explicit",
      coverSize: size,
      sizeBytes: blob.size,
      cachedAt: Date.now(),
      lastAccessedAt: Date.now(),
    };

    getCacheIndexActions().addItem(key, meta);
    this.scheduleStatsRefresh();
    persistCacheMeta(key, { key, ...meta });
  }

  async getCachedAvatarUrl(username: string): Promise<string | null> {
    const key = avatarKey(username);

    if (isNativeImageCacheAdapterAvailable()) {
      const adapter = getNativeImageCacheAdapter();
      const result = await adapter.resolveCoverImage(username);
      if (!result) {
        if (isAvatarCached(username)) {
          getCacheIndexActions().removeItem(key);
        }
        return null;
      }

      if (!isAvatarCached(username)) {
        const existingRow = await libraryDb.cacheMeta.get(key);
        if (existingRow) {
          getCacheIndexActions().addItem(key, {
            id: existingRow.id,
            type: existingRow.type,
            source: existingRow.source,
            coverSize: (existingRow as Record<string, unknown>).coverSize as
              | string
              | undefined,
            sizeBytes: existingRow.sizeBytes,
            cachedAt: existingRow.cachedAt,
            lastAccessedAt: Date.now(),
            removedFromServer: existingRow.removedFromServer,
          });
        } else {
          const syntheticMeta = {
            id: username,
            type: "cover" as const,
            source: "explicit" as const,
            coverSize: result.coverSize ?? "150",
            sizeBytes: result.sizeBytes ?? 0,
            cachedAt: Date.now(),
            lastAccessedAt: Date.now(),
          };
          getCacheIndexActions().addItem(key, syntheticMeta);
          persistCacheMeta(key, { key, ...syntheticMeta });
        }
      } else {
        getCacheIndexActions().touchItem(key);
      }

      return convertFileSrc(result.uri);
    }

    const { loaded } = useCacheIndexStore.getState();
    if (loaded && !isAvatarCached(username)) return null;

    const blob = await cacheStorage.get(key);
    if (!blob) {
      if (isAvatarCached(username)) {
        getCacheIndexActions().removeItem(key);
      }
      return null;
    }

    if (!isAvatarCached(username)) {
      const existingRow = await libraryDb.cacheMeta.get(key);
      if (existingRow) {
        getCacheIndexActions().addItem(key, {
          id: existingRow.id,
          type: existingRow.type,
          source: existingRow.source,
          coverSize: (existingRow as Record<string, unknown>).coverSize as
            | string
            | undefined,
          sizeBytes: existingRow.sizeBytes,
          cachedAt: existingRow.cachedAt,
          lastAccessedAt: Date.now(),
          removedFromServer: existingRow.removedFromServer,
        });
      } else {
        const syntheticMeta = {
          id: username,
          type: "cover" as const,
          source: "explicit" as const,
          coverSize: "150",
          sizeBytes: blob.size,
          cachedAt: Date.now(),
          lastAccessedAt: Date.now(),
        };
        getCacheIndexActions().addItem(key, syntheticMeta);
        persistCacheMeta(key, { key, ...syntheticMeta });
      }
    } else {
      getCacheIndexActions().touchItem(key);
    }

    return URL.createObjectURL(blob);
  }

  async syncCoverArt(
    onProgress?: (current: number, total: number) => void,
    concurrency = 1,
  ) {
    const useAlbumCoverForSongs =
      usePlayerStore.getState().settings.coverArt.useAlbumCoverForSongs;

    const [artists, albums, songs] = await Promise.all([
      libraryDb.artists.toArray(),
      libraryDb.albums.toArray(),
      libraryDb.songs.toArray(),
    ]);

    // Always cache every distinct coverArt we encounter, regardless of
    // useAlbumCoverForSongs.  When the setting is on, resolveCacheKey
    // resolves song covers to albumId, so we must also ensure album.id
    // is present in the cache (copying the album.coverArt blob when the
    // two IDs differ).  This guarantees offline lookups never miss.
    const queue = Array.from(
      new Set(
        [
          ...artists.map((artist) => artist.coverArt),
          ...albums.map((album) => album.coverArt),
          ...(useAlbumCoverForSongs ? [] : songs.map((song) => song.coverArt)),
        ].filter((value): value is string => Boolean(value)),
      ),
    );

    await asyncPool(
      queue,
      concurrency,
      async (coverArtId) => {
        try {
          await this.cacheCover(coverArtId, "700");
        } catch (err) {
          console.warn(
            `[cacheManager] failed to cache cover ${coverArtId}:`,
            err,
          );
        }
      },
      onProgress,
    );

    // When songs resolve to albumId, make sure album.id is also cached.
    if (useAlbumCoverForSongs) {
      for (const album of albums) {
        if (!album.id || album.id === album.coverArt) continue;

        const key = coverKey(album.id);
        if (isCoverCached(album.id)) continue;

        try {
          if (isNativeImageCacheAdapterAvailable()) {
            const adapter = getNativeImageCacheAdapter();
            const sourceResult = await adapter.resolveCoverImage(
              album.coverArt,
            );
            if (sourceResult) {
              // On iOS, re-download under the album.id key; native file copy
              // is not exposed, but re-downloading is cheap and keeps logic simple.
              await adapter.downloadCoverImage(album.id, "700");
              getCacheIndexActions().addItem(key, {
                id: album.id,
                type: "cover",
                source: "explicit",
                coverSize: "700",
                sizeBytes: sourceResult.sizeBytes ?? 0,
                cachedAt: Date.now(),
                lastAccessedAt: Date.now(),
              });
            } else {
              await this.cacheCover(album.id, "700");
            }
            continue;
          }

          const blob = await cacheStorage.get(coverKey(album.coverArt));
          if (blob) {
            await cacheStorage.put(key, blob, blob.type || "image/jpeg");
            getCacheIndexActions().addItem(key, {
              id: album.id,
              type: "cover",
              source: "explicit",
              coverSize: "700",
              sizeBytes: blob.size,
              cachedAt: Date.now(),
              lastAccessedAt: Date.now(),
            });
          } else {
            await this.cacheCover(album.id, "700");
          }
        } catch (err) {
          console.warn(
            `[cacheManager] failed to alias cover ${album.id}:`,
            err,
          );
        }
      }
    }

    await this.enforceStorageLimit();
  }

  private async cacheBulk(
    songs: { id: string; coverArt?: string; albumId?: string }[],
    onProgress?: (current: number, total: number) => void,
  ): Promise<void> {
    const seenCovers = new Set<string>();
    let completed = 0;
    const total = songs.length;
    const evictionInterval = 10;

    await Promise.all(
      songs.map(async (song) => {
        try {
          await this.cacheSong(song.id);
          const coverArtId = getSongCoverArtId({
            albumId: song.albumId,
            coverArt: song.coverArt ?? "",
          });
          if (coverArtId && !seenCovers.has(coverArtId)) {
            seenCovers.add(coverArtId);
            await this.cacheCover(coverArtId);
          }
        } catch (err) {
          console.error(`Failed to cache song ${song.id}:`, err);
        }
        completed++;
        onProgress?.(completed, total);

        if (completed % evictionInterval === 0) {
          await this.enforceStorageLimit();
        }
      }),
    );

    await this.enforceStorageLimit();
  }

  async cacheAlbum(
    albumId: string,
    onProgress?: (current: number, total: number) => void,
  ): Promise<void> {
    const album = await subsonic.albums.getOne(albumId);
    if (!album?.song) return;
    await this.cacheBulk(album.song, onProgress);
    this.recordCollectionEntry(albumKey(albumId), albumId, "album");
  }

  async cachePlaylist(
    playlistId: string,
    onProgress?: (current: number, total: number) => void,
  ): Promise<void> {
    const playlist = await subsonic.playlists.getOne(playlistId);
    if (!playlist?.entry) return;
    await this.cacheBulk(playlist.entry, onProgress);
    this.recordCollectionEntry(playlistKey(playlistId), playlistId, "playlist");
  }

  async cacheArtist(
    artistId: string,
    onProgress?: (current: number, total: number) => void,
  ): Promise<void> {
    const artist = await subsonic.artists.getOne(artistId);
    if (!artist?.album) return;

    const results = await Promise.all(
      artist.album.map((a) => subsonic.albums.getOne(a.id)),
    );

    const songs = results.flatMap((result) => {
      if (!result) return [];
      return result.song;
    });

    await this.cacheBulk(songs, onProgress);
  }

  async enforceStorageLimit(): Promise<void> {
    const { assetsQuota, lruQuota } = useCacheStore.getState().settings;
    const items = getCacheIndexItems();
    const toEvict = computeEvictionPlan(items, {
      assets: assetsQuota,
      audioLru: lruQuota,
    });
    for (const key of toEvict) {
      await this.evictItem(key);
    }
  }

  private recordCollectionEntry(
    key: string,
    id: string,
    type: "album" | "playlist",
  ): void {
    const now = Date.now();
    const meta: CachedItemMeta = {
      id,
      type,
      source: "explicit",
      sizeBytes: 0,
      cachedAt: now,
      lastAccessedAt: now,
    };
    getCacheIndexActions().addItem(key, meta);
    persistCacheMeta(key, { key, ...meta });
  }

  async evictItem(key: string): Promise<void> {
    await this.deleteCachedStorageItem(key);
    getCacheIndexActions().removeItem(key);

    await libraryDb.cacheMeta.delete(key);

    this.scheduleStatsRefresh();
    deleteCacheMeta(key);
  }

  private async deleteCachedStorageItem(key: string): Promise<void> {
    const songId = songIdFromKey(key);
    if (songId) {
      await evictNativeAudioFileIfAvailable(songId);
    }

    if (isNativeImageCacheAdapterAvailable()) {
      const isCover = key.startsWith(COVER_PREFIX) || key.startsWith("avatar:");
      if (isCover) {
        const id = key.split(":")[1];
        if (id) {
          this.nativeCoverUrlCache.delete(id);
          this.nativeCoverUrlInflight.delete(id);
          const adapter = getNativeImageCacheAdapter();
          await adapter.deleteCoverImage(id);
        }
        return;
      }
    }

    await cacheStorage.delete(key);
  }

  /**
   * Clear every `type: "audio"` entry whose `source` matches. Used by
   * the per-pool clear buttons in the storage settings UI.
   */
  async clearAudioBySource(source: CacheMetaSource): Promise<void> {
    const items = getCacheIndexItems();
    const keysToDelete = Object.entries(items)
      .filter(
        ([, meta]) =>
          (meta.type === "audio" && meta.source === source) ||
          ((meta.type === "album" || meta.type === "playlist") &&
            meta.source === source),
      )
      .map(([key]) => key);

    await Promise.all(
      keysToDelete.map((key) => this.deleteCachedStorageItem(key)),
    );
    for (const key of keysToDelete) {
      getCacheIndexActions().removeItem(key);
    }
    if (keysToDelete.length > 0) {
      await bulkDeleteCacheMeta(keysToDelete);
    }
    this.refreshStats();
  }

  /** Clear every `type: "cover"` entry regardless of source. */
  async clearAssets(): Promise<void> {
    const items = getCacheIndexItems();
    const keysToDelete = Object.entries(items)
      .filter(([, meta]) => meta.type === "cover")
      .map(([key]) => key);

    if (isNativeImageCacheAdapterAvailable()) {
      const adapter = getNativeImageCacheAdapter();
      await adapter.clearCoverImages();
      this.nativeCoverUrlCache.clear();
      this.nativeCoverUrlInflight.clear();
    }

    await Promise.all(keysToDelete.map((key) => cacheStorage.delete(key)));
    for (const key of keysToDelete) {
      getCacheIndexActions().removeItem(key);
    }
    if (keysToDelete.length > 0) {
      await bulkDeleteCacheMeta(keysToDelete);
    }
    this.refreshStats();
  }

  async listCachedItems(): Promise<CachedItemDetail[]> {
    const items = getCacheIndexItems();
    const entries = Object.entries(items);
    if (entries.length === 0) return [];

    const results: CachedItemDetail[] = [];

    for (const [key, meta] of entries) {
      let name = meta.id;
      let subtitle: string | undefined;

      if (meta.type === "audio") {
        const song = await libraryDb.songs.get(meta.id);
        if (song) {
          name = song.title || meta.id;
          subtitle = song.artist || undefined;
        }
      } else if (meta.type === "album") {
        const album = await libraryDb.albums.get(meta.id);
        if (album?.name) {
          name = album.name;
          subtitle = album.artist || undefined;
        }
      } else if (meta.type === "playlist") {
        const playlist = await libraryDb.playlists.get(meta.id);
        if (playlist?.name) {
          name = playlist.name;
        }
      } else {
        const album = await libraryDb.albums.get(meta.id);
        if (album?.name) {
          name = album.name;
        } else {
          const artist = await libraryDb.artists.get(meta.id);
          if (artist?.name) {
            name = artist.name;
          }
        }
      }

      results.push({
        key,
        id: meta.id,
        type: meta.type,
        source: meta.source,
        name,
        subtitle,
        sizeBytes: meta.sizeBytes,
        cachedAt: meta.cachedAt,
        lastAccessedAt: meta.lastAccessedAt,
        coverSize: meta.coverSize,
        removedFromServer: meta.removedFromServer,
      });
    }

    return results;
  }

  async clearAllCaches(): Promise<void> {
    // Cancel any in-flight downloads so the Worker doesn't write
    // stale cacheMeta rows after we clear them.
    audioCacheService.cancelAll();
    syncService.cancel();
    await clearNativeAudioFilesIfAvailable();

    if (isNativeImageCacheAdapterAvailable()) {
      const adapter = getNativeImageCacheAdapter();
      await adapter.clearCoverImages();
      this.nativeCoverUrlCache.clear();
      this.nativeCoverUrlInflight.clear();
    }

    await cacheStorage.clear();
    getCacheIndexActions().clear();
    await libraryDb.lyrics.clear();
    await libraryDb.cacheMeta.clear();
    this.refreshStats();
  }

  /**
   * Walk every cached explicit/smart audio entry and sync its
   * `removedFromServer` flag against the current `libraryDb.songs`
   * table. Entries whose songId no longer exists on the server keep
   * their local blob (so offline playback stays working) but are
   * flagged so the UI can label them. If a flagged song reappears
   * on the server (folder rescan, rename undo, …), the flag is
   * cleared automatically.
   *
   * Safe to call after any sync that refreshed the songs table. If
   * the songs table is empty (e.g. library caching off, fresh install)
   * this is a no-op — we'd otherwise mark every download as an
   * orphan, which would confuse users.
   */
  async reconcileRemovedFromServer(): Promise<void> {
    const songCount = await libraryDb.songs.count();
    if (songCount === 0) return;

    const items = getCacheIndexItems();
    const { setRemovedFromServer } = getCacheIndexActions();

    let removeCount = 0;
    const updates: Array<[key: string, shouldMarkRemoved: boolean]> = [];

    for (const [key, meta] of Object.entries(items)) {
      if (meta.type !== "audio") continue;
      const existsOnServer = (await libraryDb.songs.get(meta.id)) !== undefined;
      const shouldMarkRemoved = !existsOnServer;
      if (shouldMarkRemoved !== Boolean(meta.removedFromServer)) {
        if (shouldMarkRemoved) removeCount++;
        updates.push([key, shouldMarkRemoved]);
      }
    }

    if (
      removeCount > 0 &&
      removeCount >
        Object.values(items).filter((m) => m.type === "audio").length * 0.5
    ) {
      console.warn(
        `[cacheManager] Skipping remove-reconciliation: ${removeCount} cached audio items would be marked as removed. The songs table is likely incomplete.`,
      );
      return;
    }

    for (const [key, shouldMarkRemoved] of updates) {
      setRemovedFromServer(key, shouldMarkRemoved);
    }
  }

  private scheduleStatsRefresh(): void {
    if (this.statsTimer) return;
    this.statsTimer = setTimeout(() => {
      this.statsTimer = null;
      this.refreshStats();
    }, 300);
  }

  refreshStats(): void {
    refreshCacheStats();
  }

  /**
   * One-time migration: old cache keys included the size suffix
   * (e.g. `cover:al-123:300`). New keys are just `cover:<id>`.
   * For each coverArtId that has multiple old entries, keep the
   * largest size and delete the rest.
   */
  async migrateCoverCacheKeys(): Promise<void> {
    const items = getCacheIndexItems();
    const actions = getCacheIndexActions();

    const coverEntries = Object.entries(items).filter(([key]) =>
      isOldCoverKey(key),
    );

    if (coverEntries.length === 0) return;

    const byId = new Map<
      string,
      { key: string; size: string; meta: CachedItemMeta }[]
    >();
    for (const [key, meta] of coverEntries) {
      const suffix = key.slice(COVER_PREFIX.length);
      const lastColon = suffix.lastIndexOf(":");
      const id = suffix.slice(0, lastColon);
      const size = suffix.slice(lastColon + 1);
      let list = byId.get(id);
      if (!list) {
        list = [];
        byId.set(id, list);
      }
      list.push({ key, size, meta });
    }

    for (const [id, entries] of byId) {
      entries.sort((a, b) => Number(b.size) - Number(a.size));
      const best = entries[0];
      const newKey = coverKey(id);

      const blob = await cacheStorage.get(best.key);
      if (blob) {
        await cacheStorage.put(newKey, blob, blob.type || "image/jpeg");
        actions.addItem(newKey, {
          ...best.meta,
          id,
          type: "cover",
          coverSize: best.size,
        });
      }

      for (const entry of entries) {
        await cacheStorage.delete(entry.key);
        actions.removeItem(entry.key);
      }
    }

    this.refreshStats();
  }
}

export const cacheManager = new CacheManager();
