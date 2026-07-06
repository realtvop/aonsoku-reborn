import type {
  AonsokuAudioApi,
  NativeAddToUserQueueOptions,
  NativeAudioCachedAudioFile,
  NativeAudioClearFilesResult,
  NativeAudioDeleteFileResult,
  NativeAudioEvents,
  NativeAudioFileOptions,
  NativeAudioFileSizeResult,
  NativeAudioLoadOptions,
  NativeAudioMetadata,
  NativeAudioQueueItem,
  NativeAudioQueueOptions,
  NativeAudioRemoteCommand,
  NativeAudioRepeatModeOptions,
  NativeAudioResolveFileResult,
  NativeAudioSeekOptions,
  NativeAudioShuffleOptions,
  NativeAudioSource,
  NativeAudioStoreFileOptions,
  NativeCancelDownloadOptions,
  NativeDownloadAudioFileOptions,
  NativeFullState,
  NativeMarkAsShuffledOptions,
  NativePlayAtIndexOptions,
  NativeQueueSong,
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
  type DesktopAudioDownloadCompletionEventName,
  DesktopAudioDownloadManager,
} from "./download";
import { createDesktopAudioEngine } from "./engine-factory";
import {
  type DesktopQueueContentsReason,
  DesktopQueueEngine,
} from "./queue-engine";
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
  readonly #queueEngine = new DesktopQueueEngine();
  #requestId: string | undefined;
  #queueRequestSequence = 0;
  #playbackState: NativeAudioEvents["playbackStateChanged"]["state"] = "idle";
  #currentTime = 0;
  #duration = 0;
  #currentSource: NativeAudioQueueItem | null = null;

  constructor(options: NativeAudioServiceOptions = {}) {
    this.#engine = options.engine ?? createDesktopAudioEngine();
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
    this.#queueEngine.delegate = {
      queueEngineLoadSong: (_engine, song, autoplay, startTime) =>
        this.#loadQueueSong(song, { autoplay, startTime }),
      queueEngineDidAdvanceTo: (engine, index, songId, reason) => {
        this.#emit("queueStateChanged", {
          requestId: this.#requestId,
          currentIndex: index,
          songId,
          reason,
          isInUserQueue: engine.isInUserQueue,
        });
      },
      queueEngineDidChangeContents: (_engine, reason) => {
        this.#emitQueueContentsChanged(reason);
      },
      queueEngineDidExhaustQueue: () => this.#handleQueueExhausted(),
      queueEngineSeekToStart: (_engine, song) =>
        this.#seekQueueSongToStart(song),
    };
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

  setRepeatMode(options: NativeAudioRepeatModeOptions): Promise<void> {
    this.#queueEngine.setLoopState(options.mode);
    return Promise.resolve();
  }

  setShuffle(options: NativeAudioShuffleOptions): Promise<void> {
    this.#queueEngine.setShuffleActive(options.enabled);
    return Promise.resolve();
  }

  markAsShuffled(options: NativeMarkAsShuffledOptions): Promise<void> {
    this.#queueEngine.markAsShuffled(options.originalSongs);
    return Promise.resolve();
  }

  async setQueue(options: NativeAudioQueueOptions): Promise<void> {
    for (const item of options.items) {
      this.#rememberDownloadableSource(item.source);
    }

    await this.#queueEngine.setContextQueue({
      songs: options.items.map(queueItemToNativeQueueSong),
      currentIndex: options.index,
      autoplay: false,
    });
    this.#emitQueueContentsChanged("queue-edit");
  }

  async skipToNext(): Promise<void> {
    if (!this.#hasNativeQueue()) return;

    await this.#queueEngine.skipToNext();
  }

  async skipToPrevious(): Promise<void> {
    if (!this.#hasNativeQueue()) return;

    await this.#queueEngine.skipToPrevious(this.#currentTime);
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
      this.#queueEngine.clear();
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
    if (options.repeatMode) {
      this.#queueEngine.setLoopState(options.repeatMode);
    }
    await this.#queueEngine.setContextQueue(options);
    this.#emitQueueContentsChanged("queue-edit");
  }

  async updateContextQueue(
    options: NativeUpdateContextQueueOptions,
  ): Promise<void> {
    this.#rememberQueueSongs(options.songs);
    await this.#queueEngine.updateContextQueue(
      options.songs,
      options.currentIndex,
    );
  }

  reorderContextQueue(
    options: NativeReorderContextQueueOptions,
  ): Promise<void> {
    this.#queueEngine.reorderContextQueue(options.fromIndex, options.toIndex);
    return Promise.resolve();
  }

  addToUserQueue(options: NativeAddToUserQueueOptions): Promise<void> {
    this.#rememberQueueSongs(options.songs);
    this.#queueEngine.addToUserQueue(options.songs, options.position);
    return Promise.resolve();
  }

  removeFromUserQueue(
    options: NativeRemoveFromUserQueueOptions,
  ): Promise<void> {
    this.#queueEngine.removeFromUserQueue(options.indices);
    return Promise.resolve();
  }

  clearUserQueue(): Promise<void> {
    this.#queueEngine.clearUserQueue();
    return Promise.resolve();
  }

  async playAtIndex(options: NativePlayAtIndexOptions): Promise<void> {
    await this.#queueEngine.playAtIndex(options.index, options.startTime);
  }

  getFullState(): Promise<NativeFullState> {
    return Promise.resolve(
      this.#queueEngine.getFullState({
        currentTime: this.#currentTime,
        duration: this.#duration,
        isPlaying: this.#playbackState === "playing",
      }),
    );
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
    const hasNativeQueue = this.#hasNativeQueue();

    return {
      isPlaying: this.#playbackState === "playing",
      hasCurrent: this.#currentSource !== null,
      hasNativeQueue,
      hasPrevious: hasNativeQueue && this.#queueEngine.hasPrevious,
      hasNext: hasNativeQueue && this.#queueEngine.hasNext,
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
        this.#handlePlaybackEnded(event).catch((error) => {
          this.#emitFailure(error);
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

  #emitQueueContentsChanged(reason: DesktopQueueContentsReason): void {
    this.#emit("queueContentsChanged", {
      requestId: this.#requestId,
      reason,
    });
  }

  #hasNativeQueue(): boolean {
    return this.#queueEngine.contextSongs.length > 0;
  }

  private notImplemented<T>(method: keyof AonsokuAudioApi): Promise<T> {
    return Promise.reject(new DesktopNativeAudioNotImplementedError(method));
  }

  async #loadQueueSong(
    song: NativeQueueSong,
    options: {
      autoplay: boolean;
      startTime?: number;
    },
  ): Promise<void> {
    const item = nativeQueueSongToQueueItem(song);

    await this.load({
      requestId: `desktop-native-queue-${++this.#queueRequestSequence}`,
      source: item.source,
      metadata: item.metadata,
      autoplay: options.autoplay,
      startTime: options.startTime,
    });
  }

  async #seekQueueSongToStart(_song: NativeQueueSong): Promise<void> {
    this.#currentTime = 0;
    await this.seek({ position: 0 });
    await this.play();
  }

  async #handleQueueExhausted(): Promise<void> {
    try {
      await this.#engine.pause();
      await this.#engine.seek(0);
      this.#playbackState = "ended";
      this.#currentTime = 0;
      this.#emit("playbackStateChanged", {
        requestId: this.#requestId,
        state: "ended",
      });
      this.#emit("ended", {
        requestId: this.#requestId,
        reason: "finished",
      });
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  async #handlePlaybackEnded(
    event: Extract<DesktopAudioEngineEvent, { type: "ended" }>,
  ): Promise<void> {
    if (this.#hasNativeQueue()) {
      try {
        await this.#queueEngine.handleEnded();
      } catch (error) {
        this.#emitFailure(error);
      }
      return;
    }

    this.#playbackState = "ended";
    this.#emit("ended", {
      requestId: this.#requestId,
      reason: event.reason,
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
    const code = getErrorCode(error);

    return {
      ...(code ? { code } : {}),
      message: error.message,
    };
  }

  return {
    message: "Desktop native audio failed.",
  };
}

function getErrorCode(error: Error): string | undefined {
  const maybeErrorWithCode = error as Error & { code?: unknown };

  return typeof maybeErrorWithCode.code === "string"
    ? maybeErrorWithCode.code
    : undefined;
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

function queueItemToNativeQueueSong(
  item: NativeAudioQueueItem,
  index: number,
): NativeQueueSong {
  const id = getQueueItemId(item) ?? `queue-item-${index}`;
  const streamUrl =
    item.source.kind === "stream" ||
    item.source.kind === "blob" ||
    item.source.kind === "radio"
      ? item.source.url
      : "";

  return {
    id,
    title: item.metadata?.title ?? id,
    artist: item.metadata?.artist ?? "",
    album: item.metadata?.album ?? "",
    duration: item.metadata?.duration ?? 0,
    coverArtId: item.metadata?.coverArtId,
    streamUrl,
    cachedFileUri:
      item.source.kind === "native-file" ? item.source.uri : undefined,
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
