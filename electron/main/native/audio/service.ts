import type {
  AonsokuAudioApi,
  NativeAudioCachedAudioFile,
  NativeAudioClearFilesResult,
  NativeAudioDeleteFileResult,
  NativeAudioEvents,
  NativeAudioFileOptions,
  NativeAudioFileSizeResult,
  NativeAudioLoadOptions,
  NativeAudioMetadata,
  NativeAudioRemoteCommand,
  NativeAudioQueueOptions,
  NativeAudioQueueItem,
  NativeAudioRepeatModeOptions,
  NativeAudioResolveFileResult,
  NativeAudioSeekOptions,
  NativeAudioShuffleOptions,
  NativeAudioSource,
  NativeAudioStoreFileOptions,
  NativeAddToUserQueueOptions,
  NativeCancelDownloadOptions,
  NativeDownloadAudioFileOptions,
  NativeFullState,
  NativeMarkAsShuffledOptions,
  NativeQueueSong,
  NativePlayAtIndexOptions,
  NativeRemotePlaybackStateOptions,
  NativeRemoveFromUserQueueOptions,
  NativeReorderContextQueueOptions,
  NativeResolveSongsResult,
  NativeScrobbleBufferResult,
  NativeSetContextQueueOptions,
  NativeSetSleepTimerOptions,
  NativeSetSystemVolumeOptions,
  NativeSleepTimerRemainingResult,
  NativeSystemVolumeResult,
  NativeUpdateContextQueueOptions,
} from "@aonsoku/audio-contract";
import { DesktopAudioFileStore } from "./cache";
import {
  DesktopAudioDownloadManager,
  type DesktopAudioDownloadCompletionEventName,
} from "./download";
import { MpvAudioEngine } from "./mpv";
import {
  DesktopNativeAudioUnsupportedSourceError,
  resolveNativeAudioSource,
} from "./source";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineEvent,
  NativeAudioServiceEvent,
  NativeAudioServiceEventListener,
} from "./types";

export class DesktopNativeAudioNotImplementedError extends Error {
  constructor(method: keyof AonsokuAudioApi) {
    super(`Desktop native audio bridge method ${method} is not implemented.`);
    this.name = "DesktopNativeAudioNotImplementedError";
  }
}

export interface NativeAudioServiceOptions {
  engine?: DesktopAudioEngine;
  audioFileStore?: DesktopAudioFileStore;
  audioCacheDirectory?: string | (() => string | Promise<string>);
  downloadUrlResolver?: DesktopAudioDownloadUrlResolver;
  cacheLoadedStreams?: boolean;
}

export type DesktopAudioDownloadUrlResolver = (
  options: NativeDownloadAudioFileOptions,
) => string | null | Promise<string | null>;

interface StartDownloadOptions extends NativeDownloadAudioFileOptions {
  completionEventName: DesktopAudioDownloadCompletionEventName;
  reportProgress: boolean;
  reportFailure: boolean;
  skipIfCached?: boolean;
}

export interface NativeAudioControlState {
  isPlaying: boolean;
  hasCurrent: boolean;
  hasNativeQueue: boolean;
  hasPrevious: boolean;
  hasNext: boolean;
}

export class NativeAudioService implements AonsokuAudioApi {
  readonly #engine: DesktopAudioEngine;
  readonly #audioFiles: DesktopAudioFileStore;
  readonly #downloadManager: DesktopAudioDownloadManager;
  readonly #downloadUrlResolver: DesktopAudioDownloadUrlResolver | null;
  readonly #cacheLoadedStreams: boolean;
  readonly #listeners = new Set<NativeAudioServiceEventListener>();
  readonly #streamUrlsBySongId = new Map<string, string>();
  #requestId: string | undefined;
  #queueRequestSequence = 0;
  #queueItems: NativeAudioQueueItem[] = [];
  #contextSongs: NativeQueueSong[] = [];
  #queueIndex = -1;
  #hasNativeQueue = false;
  #playbackState: NativeAudioEvents["playbackStateChanged"]["state"] = "idle";
  #currentTime = 0;
  #duration = 0;
  #currentSource: NativeAudioQueueItem | null = null;

  constructor(options: NativeAudioServiceOptions = {}) {
    this.#engine = options.engine ?? new MpvAudioEngine();
    this.#audioFiles =
      options.audioFileStore ??
      new DesktopAudioFileStore({
        cacheDirectory: options.audioCacheDirectory,
      });
    this.#downloadUrlResolver = options.downloadUrlResolver ?? null;
    this.#cacheLoadedStreams = options.cacheLoadedStreams ?? false;
    this.#downloadManager = new DesktopAudioDownloadManager({
      audioFiles: this.#audioFiles,
      onProgress: (event) => this.#emit("downloadProgress", event),
      onCompleted: (eventName, event) =>
        this.#emitDownloadCompleted(eventName, event),
      onFailed: (event) => this.#emit("downloadFailed", event),
    });
    this.#engine.onEvent((event) => this.#handleEngineEvent(event));
  }

  async load(options: NativeAudioLoadOptions): Promise<void> {
    this.#rememberDownloadableSource(options.source);
    this.#requestId = options.requestId;
    this.#currentSource = {
      source: options.source,
      metadata: options.metadata,
    };
    this.#duration = options.metadata?.duration ?? 0;
    this.#currentTime = options.startTime ?? 0;

    try {
      await this.#engine.load({
        source: resolveNativeAudioSource(options.source),
        metadata: options.metadata,
        autoplay: options.autoplay,
        startTime: options.startTime,
      });
      this.#startBackgroundStreamCache(options.source);
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  async play(): Promise<void> {
    try {
      await this.#engine.play();
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  async pause(): Promise<void> {
    try {
      await this.#engine.pause();
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  async stop(): Promise<void> {
    try {
      await this.#engine.stop();
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  async seek(options: NativeAudioSeekOptions): Promise<void> {
    try {
      await this.#engine.seek(Math.max(0, options.position));
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  setRepeatMode(_options: NativeAudioRepeatModeOptions): Promise<void> {
    return Promise.resolve();
  }

  setShuffle(_options: NativeAudioShuffleOptions): Promise<void> {
    return Promise.resolve();
  }

  markAsShuffled(_options: NativeMarkAsShuffledOptions): Promise<void> {
    return this.notImplemented("markAsShuffled");
  }

  async setQueue(options: NativeAudioQueueOptions): Promise<void> {
    for (const item of options.items) {
      this.#rememberDownloadableSource(item.source);
    }

    this.#queueItems = [...options.items];
    this.#contextSongs = [];
    this.#queueIndex = normalizeQueueIndex(options.index, this.#queueItems);
    this.#hasNativeQueue = this.#queueItems.length > 0;

    this.#emit("queueContentsChanged", {
      requestId: this.#requestId,
      reason: "queue-edit",
    });

    if (this.#queueIndex >= 0) {
      await this.#loadQueueIndex(this.#queueIndex, {
        reason: "skip",
        autoplay: false,
      });
    }
  }

  async skipToNext(): Promise<void> {
    if (
      !this.#hasNativeQueue ||
      this.#queueIndex >= this.#queueItems.length - 1
    ) {
      return this.notImplemented("skipToNext");
    }

    await this.#loadQueueIndex(this.#queueIndex + 1, {
      reason: "next",
      autoplay: true,
    });
  }

  async skipToPrevious(): Promise<void> {
    if (!this.#hasNativeQueue || this.#queueIndex <= 0) {
      return this.notImplemented("skipToPrevious");
    }

    await this.#loadQueueIndex(this.#queueIndex - 1, {
      reason: "previous",
      autoplay: true,
    });
  }

  async updateMetadata(metadata: NativeAudioMetadata): Promise<void> {
    try {
      await this.#engine.updateMetadata(metadata);
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  updateRemotePlaybackState(
    _options: NativeRemotePlaybackStateOptions,
  ): Promise<void> {
    return this.notImplemented("updateRemotePlaybackState");
  }

  clearRemotePlaybackState(): Promise<void> {
    return this.notImplemented("clearRemotePlaybackState");
  }

  preload(_options: { source: NativeAudioSource }): Promise<void> {
    return this.notImplemented("preload");
  }

  async clear(): Promise<void> {
    try {
      await this.#engine.clear();
      this.#requestId = undefined;
      this.#queueRequestSequence = 0;
      this.#queueItems = [];
      this.#contextSongs = [];
      this.#queueIndex = -1;
      this.#hasNativeQueue = false;
      this.#playbackState = "idle";
      this.#currentTime = 0;
      this.#duration = 0;
      this.#currentSource = null;
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  storeAudioFile(
    options: NativeAudioStoreFileOptions,
  ): Promise<NativeAudioCachedAudioFile> {
    return this.#audioFiles.storeAudioFile(options);
  }

  resolveAudioFile(
    options: NativeAudioFileOptions,
  ): Promise<NativeAudioResolveFileResult> {
    return this.#audioFiles
      .resolveAudioFile(options.songId)
      .then((file) => ({ file }));
  }

  getAudioFileSize(
    options: NativeAudioFileOptions,
  ): Promise<NativeAudioFileSizeResult> {
    return this.#audioFiles
      .getAudioFileSize(options.songId)
      .then((sizeBytes) => ({ sizeBytes }));
  }

  deleteAudioFile(
    options: NativeAudioFileOptions,
  ): Promise<NativeAudioDeleteFileResult> {
    return this.#audioFiles
      .deleteAudioFile(options.songId)
      .then((deleted) => ({ deleted }));
  }

  clearAudioFiles(): Promise<NativeAudioClearFilesResult> {
    return this.#audioFiles
      .clearAudioFiles()
      .then((deletedCount) => ({ deletedCount }));
  }

  async setContextQueue(options: NativeSetContextQueueOptions): Promise<void> {
    this.#rememberQueueSongs(options.songs);
    this.#contextSongs = [...options.songs];
    this.#queueItems = options.songs.map(nativeQueueSongToQueueItem);
    this.#queueIndex = normalizeQueueIndex(
      options.currentIndex,
      this.#queueItems,
    );
    this.#hasNativeQueue = this.#queueItems.length > 0;

    this.#emit("queueContentsChanged", {
      requestId: this.#requestId,
      reason: "queue-edit",
    });

    if (this.#queueIndex >= 0) {
      await this.#loadQueueIndex(this.#queueIndex, {
        reason: "skip",
        autoplay: options.autoplay ?? true,
        startTime: options.startTime,
      });
    }
  }

  updateContextQueue(options: NativeUpdateContextQueueOptions): Promise<void> {
    this.#rememberQueueSongs(options.songs);
    this.#contextSongs = [...options.songs];
    this.#queueItems = options.songs.map(nativeQueueSongToQueueItem);
    this.#queueIndex = normalizeQueueIndex(
      options.currentIndex,
      this.#queueItems,
    );
    this.#hasNativeQueue = this.#queueItems.length > 0;

    this.#emit("queueContentsChanged", {
      requestId: this.#requestId,
      reason: "queue-edit",
    });

    return Promise.resolve();
  }

  reorderContextQueue(
    _options: NativeReorderContextQueueOptions,
  ): Promise<void> {
    return this.notImplemented("reorderContextQueue");
  }

  addToUserQueue(_options: NativeAddToUserQueueOptions): Promise<void> {
    return this.notImplemented("addToUserQueue");
  }

  removeFromUserQueue(
    _options: NativeRemoveFromUserQueueOptions,
  ): Promise<void> {
    return this.notImplemented("removeFromUserQueue");
  }

  clearUserQueue(): Promise<void> {
    return this.notImplemented("clearUserQueue");
  }

  playAtIndex(_options: NativePlayAtIndexOptions): Promise<void> {
    return this.notImplemented("playAtIndex");
  }

  getFullState(): Promise<NativeFullState> {
    const currentItem = this.#queueItems[this.#queueIndex] ?? null;

    return Promise.resolve({
      contextQueue: {
        songs: this.#contextSongs,
        currentIndex: Math.max(0, this.#queueIndex),
        sourceId: null,
        sourceName: null,
      },
      userQueue: [],
      originalContextSongs: this.#contextSongs,
      originalUserSongs: [],
      shuffleHistory: [],
      shuffleStartHistory: [],
      playedUserQueueHistory: [],
      isInUserQueue: false,
      isShuffleActive: false,
      loopState: "off",
      isPlaying: this.#playbackState === "playing",
      currentTime: this.#currentTime,
      duration: this.#duration,
      currentSongId: currentItem ? getQueueItemId(currentItem) : null,
      isRestored: false,
    });
  }

  resolveSongs(_options: { ids: string[] }): Promise<NativeResolveSongsResult> {
    return this.notImplemented("resolveSongs");
  }

  getScrobbleBuffer(): Promise<NativeScrobbleBufferResult> {
    return this.notImplemented("getScrobbleBuffer");
  }

  clearScrobbleBuffer(): Promise<void> {
    return this.notImplemented("clearScrobbleBuffer");
  }

  downloadAudioFile(options: NativeDownloadAudioFileOptions): Promise<void> {
    return this.#startDownload({
      ...options,
      completionEventName: "downloadCompleted",
      reportProgress: true,
      reportFailure: true,
    });
  }

  cancelDownload(options?: NativeCancelDownloadOptions): Promise<void> {
    if (options?.songId) {
      this.#downloadManager.cancel(options.songId);
    } else {
      this.#downloadManager.cancelAll();
    }

    return Promise.resolve();
  }

  setSystemVolume(
    _options: NativeSetSystemVolumeOptions,
  ): Promise<NativeSystemVolumeResult> {
    return this.notImplemented("setSystemVolume");
  }

  getSystemVolume(): Promise<NativeSystemVolumeResult> {
    return this.notImplemented("getSystemVolume");
  }

  setVolumeHUDEnabled(_options: { enabled: boolean }): Promise<void> {
    return Promise.resolve();
  }

  setLikeActive(_options: { active: boolean }): Promise<void> {
    return Promise.resolve();
  }

  setSleepTimer(_options: NativeSetSleepTimerOptions): Promise<void> {
    return this.notImplemented("setSleepTimer");
  }

  cancelSleepTimer(): Promise<void> {
    return this.notImplemented("cancelSleepTimer");
  }

  getSleepTimerRemaining(): Promise<NativeSleepTimerRemainingResult> {
    return this.notImplemented("getSleepTimerRemaining");
  }

  onEvent(listener: NativeAudioServiceEventListener): () => void {
    this.#listeners.add(listener);

    return () => {
      this.#listeners.delete(listener);
    };
  }

  destroy(): Promise<void> | void {
    this.#downloadManager.cancelAll();
    return this.#engine.destroy?.();
  }

  getControlState(): NativeAudioControlState {
    return {
      isPlaying: this.#playbackState === "playing",
      hasCurrent: this.#currentSource !== null,
      hasNativeQueue: this.#hasNativeQueue,
      hasPrevious: this.#hasNativeQueue && this.#queueIndex > 0,
      hasNext:
        this.#hasNativeQueue && this.#queueIndex < this.#queueItems.length - 1,
    };
  }

  async handleRemoteCommand(
    command: NativeAudioRemoteCommand,
  ): Promise<boolean> {
    switch (command) {
      case "play":
        if (!this.#currentSource) return false;
        await this.play();
        return true;
      case "pause":
        if (!this.#currentSource) return false;
        await this.pause();
        return true;
      case "togglePlayPause":
        if (!this.#currentSource) return false;
        if (this.#playbackState === "playing") {
          await this.pause();
        } else {
          await this.play();
        }
        return true;
      case "next":
        if (!this.getControlState().hasNext) return false;
        await this.skipToNext();
        return true;
      case "previous":
        if (!this.getControlState().hasPrevious) return false;
        await this.skipToPrevious();
        return true;
      default:
        return false;
    }
  }

  emitRemoteCommand(command: NativeAudioRemoteCommand): void {
    this.#emit("remoteCommand", {
      requestId: this.#requestId,
      command,
    });
  }

  #handleEngineEvent(event: DesktopAudioEngineEvent): void {
    switch (event.type) {
      case "playbackStateChanged":
        this.#playbackState = event.state;
        this.#emit("playbackStateChanged", {
          requestId: this.#requestId,
          state: event.state,
        });
        break;
      case "progress":
        this.#currentTime = event.currentTime;
        this.#duration = event.duration;
        this.#emit("progress", {
          requestId: this.#requestId,
          currentTime: event.currentTime,
          duration: event.duration,
          bufferedTime: event.bufferedTime,
        });
        break;
      case "durationChanged":
        this.#duration = event.duration;
        this.#emit("durationChanged", {
          requestId: this.#requestId,
          duration: event.duration,
        });
        break;
      case "bufferingChanged":
        this.#emit("bufferingChanged", {
          requestId: this.#requestId,
          isBuffering: event.isBuffering,
        });
        break;
      case "ended":
        this.#playbackState = "ended";
        this.#emit("ended", {
          requestId: this.#requestId,
          reason: event.reason,
        });
        break;
      case "error":
        this.#emit("error", {
          requestId: this.#requestId,
          code: event.code,
          message: event.message,
        });
        break;
    }
  }

  #emitFailure(error: unknown): void {
    this.#playbackState = "failed";
    this.#emit("playbackStateChanged", {
      requestId: this.#requestId,
      state: "failed",
    });
    this.#emit("error", {
      requestId: this.#requestId,
      ...toNativeAudioErrorEvent(error),
    });
  }

  #emit<TEvent extends keyof NativeAudioEvents>(
    eventName: TEvent,
    event: NativeAudioEvents[TEvent],
  ): void {
    const payload = {
      eventName,
      event,
    } as NativeAudioServiceEvent;

    for (const listener of this.#listeners) {
      listener(payload);
    }
  }

  #emitDownloadCompleted(
    eventName: DesktopAudioDownloadCompletionEventName,
    event:
      | NativeAudioEvents["downloadCompleted"]
      | NativeAudioEvents["streamCacheCompleted"],
  ): void {
    if (eventName === "downloadCompleted") {
      this.#emit("downloadCompleted", event);
      return;
    }

    this.#emit("streamCacheCompleted", event);
  }

  async #startDownload(options: StartDownloadOptions): Promise<void> {
    if (!options.songId) {
      throw new Error("Missing songId for desktop audio download.");
    }

    try {
      const url = await this.#resolveDownloadUrl(options);
      if (!url) {
        throw new Error(
          `No desktop audio stream URL is available for song ${options.songId}.`,
        );
      }

      this.#downloadManager.download({
        songId: options.songId,
        url,
        completionEventName: options.completionEventName,
        reportProgress: options.reportProgress,
        reportFailure: options.reportFailure,
        skipIfCached: options.skipIfCached,
      });
    } catch (error) {
      if (!options.reportFailure) return;

      this.#emit("downloadFailed", {
        songId: options.songId,
        error: error instanceof Error ? error.message : "Download failed.",
      });
    }
  }

  async #resolveDownloadUrl(
    options: NativeDownloadAudioFileOptions,
  ): Promise<string | null> {
    const resolvedByOption = await this.#downloadUrlResolver?.(options);
    const sourceUrl =
      resolvedByOption ?? this.#streamUrlsBySongId.get(options.songId);

    if (!sourceUrl) return null;

    return prepareDownloadUrl(sourceUrl, options);
  }

  #startBackgroundStreamCache(source: NativeAudioSource): void {
    if (
      !this.#cacheLoadedStreams ||
      source.kind !== "stream" ||
      !source.songId
    ) {
      return;
    }

    this.#startDownload({
      songId: source.songId,
      completionEventName: "streamCacheCompleted",
      reportProgress: false,
      reportFailure: false,
      skipIfCached: true,
    }).catch(() => undefined);
  }

  #rememberDownloadableSource(source: NativeAudioSource): void {
    if (source.kind !== "stream" || !source.songId) return;

    this.#streamUrlsBySongId.set(source.songId, source.url);
  }

  #rememberQueueSongs(songs: NativeQueueSong[]): void {
    for (const song of songs) {
      this.#streamUrlsBySongId.set(song.id, song.streamUrl);
    }
  }

  private notImplemented<T>(method: keyof AonsokuAudioApi): Promise<T> {
    return Promise.reject(new DesktopNativeAudioNotImplementedError(method));
  }

  async #loadQueueIndex(
    index: number,
    options: {
      reason: NativeAudioEvents["queueStateChanged"]["reason"];
      autoplay: boolean;
      startTime?: number;
    },
  ): Promise<void> {
    const item = this.#queueItems[index];
    if (!item) return this.notImplemented("playAtIndex");

    this.#queueIndex = index;
    await this.load({
      requestId: `desktop-native-queue-${++this.#queueRequestSequence}`,
      source: item.source,
      metadata: item.metadata,
      autoplay: options.autoplay,
      startTime: options.startTime,
    });

    this.#emit("queueStateChanged", {
      requestId: this.#requestId,
      currentIndex: this.#queueIndex,
      songId: getQueueItemId(item) ?? "",
      reason: options.reason,
      isInUserQueue: false,
    });
  }
}

export class DesktopNativeAudioService extends NativeAudioService {}

function toNativeAudioErrorEvent(
  error: unknown,
): Omit<NativeAudioEvents["error"], "requestId"> {
  if (error instanceof DesktopNativeAudioUnsupportedSourceError) {
    return {
      code: error.code,
      message: error.message,
    };
  }

  if (error instanceof Error) {
    return {
      message: error.message,
    };
  }

  return {
    message: "Desktop native audio failed.",
  };
}

function normalizeQueueIndex(
  index: number,
  items: NativeAudioQueueItem[],
): number {
  if (items.length === 0) return -1;
  return Math.max(0, Math.min(index, items.length - 1));
}

function nativeQueueSongToQueueItem(
  song: NativeQueueSong,
): NativeAudioQueueItem {
  return {
    source: song.cachedFileUri
      ? {
          kind: "native-file",
          uri: song.cachedFileUri,
          songId: song.id,
        }
      : {
          kind: "stream",
          url: song.streamUrl,
          songId: song.id,
        },
    metadata: {
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration,
      artworkUrl: song.coverArtId,
    },
  };
}

function getQueueItemId(item: NativeAudioQueueItem): string | null {
  switch (item.source.kind) {
    case "stream":
    case "blob":
    case "native-file":
      return item.source.songId ?? null;
    case "radio":
      return item.source.radioId ?? null;
  }
}

function prepareDownloadUrl(
  sourceUrl: string,
  options: NativeDownloadAudioFileOptions,
): string {
  const url = new URL(sourceUrl);

  if (!url.searchParams.has("id")) {
    url.searchParams.set("id", options.songId);
  }

  url.searchParams.set("estimateContentLength", "true");

  if (options.maxBitRate !== undefined) {
    url.searchParams.set("maxBitRate", options.maxBitRate.toString());
  }

  if (options.format) {
    url.searchParams.set("format", options.format);
  }

  return url.toString();
}
