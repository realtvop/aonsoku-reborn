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
  NativeRemoteControlCommandEvent,
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
import { nativeLogger } from "../debug/native-logger";
import { DesktopAudioFileStore } from "./cache";
import {
  type DesktopAudioDownloadCompletionEventName,
  DesktopAudioDownloadManager,
} from "./download";
import { createDesktopAudioEngine } from "./engine-factory";
import { DesktopPlaybackStateStore } from "./playback-state-store";
import {
  type DesktopQueueContentsReason,
  DesktopQueueEngine,
} from "./queue-engine";
import { DesktopScrobbleBuffer } from "./scrobble-buffer";
import {
  DesktopNativeAudioUnsupportedSourceError,
  resolveNativeAudioSourceWithCache,
} from "./source";
import {
  createDesktopSystemAudioAdapter,
  type DesktopSystemAudioAdapter,
} from "./system-adapter";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineDiagnostics,
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
  streamUrlResolver?: (url: string) => string;
  artworkUrlResolver?: (artworkUrl: string | undefined) => string | undefined;
  cacheLoadedStreams?: boolean;
  systemAudioAdapter?: DesktopSystemAudioAdapter;
  playbackStateStore?: DesktopPlaybackStateStore;
  deferPlaybackRestore?: boolean;
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
  readonly #streamUrlResolver: (url: string) => string;
  readonly #artworkUrlResolver: (
    artworkUrl: string | undefined,
  ) => string | undefined;
  readonly #cacheLoadedStreams: boolean;
  readonly #systemAudio: DesktopSystemAudioAdapter;
  readonly #listeners = new Set<NativeAudioServiceEventListener>();
  readonly #unsubscribeFromEngine: () => void;
  #startupAvailabilityError: Omit<
    NativeAudioEvents["error"],
    "requestId"
  > | null = null;
  readonly #streamUrlsBySongId = new Map<string, string>();
  readonly #queueEngine = new DesktopQueueEngine();
  readonly #scrobbleBuffer = new DesktopScrobbleBuffer();
  readonly #playbackStateStore: DesktopPlaybackStateStore;
  #requestId: string | undefined;
  #queueRequestSequence = 0;
  #sleepTimerMode: NativeSetSleepTimerOptions["mode"] = "duration";
  #sleepTimerDeadlineMs = 0;
  #sleepTimerHandle: ReturnType<typeof setTimeout> | null = null;
  #playbackState: NativeAudioEvents["playbackStateChanged"]["state"] = "idle";
  #currentTime = 0;
  #duration = 0;
  #playerVolume = 1;
  #isBuffering = false;
  #currentSource: NativeAudioQueueItem | null = null;
  #remotePlaybackState: NativeRemotePlaybackStateOptions | null = null;
  #readyPromise: Promise<void> | null = null;
  #playbackCommandTail: Promise<void> = Promise.resolve();

  constructor(options: NativeAudioServiceOptions = {}) {
    this.#engine = options.engine ?? createDesktopAudioEngine();
    this.#audioFiles =
      options.audioFileStore ??
      new DesktopAudioFileStore({
        cacheDirectory: options.audioCacheDirectory,
      });
    this.#downloadUrlResolver = options.downloadUrlResolver ?? null;
    this.#streamUrlResolver = options.streamUrlResolver ?? ((url) => url);
    this.#artworkUrlResolver = options.artworkUrlResolver ?? ((url) => url);
    this.#cacheLoadedStreams = options.cacheLoadedStreams ?? true;
    this.#systemAudio =
      options.systemAudioAdapter ?? createDesktopSystemAudioAdapter();
    this.#playbackStateStore =
      options.playbackStateStore ?? new DesktopPlaybackStateStore();
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
        nativeLogger.info(
          `advanced to index=${index} songId=${songId} reason=${reason}`,
          "audio-service",
        );
        this.#persistPlaybackState();
        this.#emit("queueStateChanged", {
          requestId: this.#requestId,
          currentIndex: index,
          songId,
          reason,
          isInUserQueue: engine.isInUserQueue,
        });
      },
      queueEngineDidChangeContents: (_engine, reason) => {
        this.#persistPlaybackState();
        this.#emitQueueContentsChanged(reason);
      },
      queueEngineDidExhaustQueue: () => this.#handleQueueExhausted(),
      queueEngineSeekToStart: (_engine, song) =>
        this.#seekQueueSongToStart(song),
    };
    this.#unsubscribeFromEngine = this.#engine.onEvent((event) =>
      this.#handleEngineEvent(event),
    );
    if (!options.deferPlaybackRestore) this.ready();
    this.#scheduleStartupAvailabilityCheck();
  }

  ready(): Promise<void> {
    this.#readyPromise ??= this.#enqueuePlaybackCommand(() =>
      this.#restorePlaybackState(),
    ).catch((error) => this.#emitFailure(error));
    return this.#readyPromise;
  }

  load(options: NativeAudioLoadOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() =>
      this.#runQueueTransaction(() => this.#load(options)),
    );
  }

  async #load(options: NativeAudioLoadOptions): Promise<void> {
    this.#rememberDownloadableSource(options.source);
    this.#stopScrobbleTracking();
    this.#requestId = options.requestId;
    this.#currentSource = {
      source: options.source,
      metadata: options.metadata,
    };
    this.#duration = options.metadata?.duration ?? 0;
    this.#currentTime = options.startTime ?? 0;
    nativeLogger.debug(
      `load source=${options.source.kind} autoplay=${options.autoplay ?? false}`,
      "audio-service",
    );

    try {
      await this.#engine.load({
        source: await resolveNativeAudioSourceWithCache(options.source, {
          streamUrlResolver: this.#streamUrlResolver,
          audioFileResolver: this.#audioFiles,
        }),
        metadata: this.#normalizeMetadata(options.metadata),
        autoplay: options.autoplay,
        startTime: options.startTime,
      });
      this.#startScrobbleTrackingForLoad(options);
      this.#startBackgroundStreamCache(options.source);
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  play(): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#play());
  }

  async #play(): Promise<void> {
    nativeLogger.debug("play", "audio-service");
    try {
      await this.#engine.play();
      this.#scrobbleBuffer.resumeTracking();
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  pause(): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#pause());
  }

  async #pause(): Promise<void> {
    nativeLogger.debug("pause", "audio-service");
    try {
      await this.#engine.pause();
      this.#scrobbleBuffer.pauseTracking();
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  stop(): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#stop());
  }

  async #stop(): Promise<void> {
    nativeLogger.debug("stop", "audio-service");
    try {
      await this.#engine.stop();
      this.#stopScrobbleTracking();
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  seek(options: NativeAudioSeekOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#seek(options));
  }

  async #seek(options: NativeAudioSeekOptions): Promise<void> {
    nativeLogger.debug(`seek ${options.position}s`, "audio-service");
    try {
      await this.#engine.seek(Math.max(0, options.position));
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  setRepeatMode(options: NativeAudioRepeatModeOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() => {
      this.#queueEngine.setLoopState(options.mode);
      this.#persistPlaybackState();
    });
  }

  setShuffle(options: NativeAudioShuffleOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() => {
      this.#queueEngine.setShuffleActive(options.enabled);
      this.#persistPlaybackState();
    });
  }

  markAsShuffled(options: NativeMarkAsShuffledOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() => {
      this.#queueEngine.markAsShuffled(options.originalSongs);
      this.#persistPlaybackState();
    });
  }

  setQueue(options: NativeAudioQueueOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() =>
      this.#runQueueTransaction(() => this.#setQueue(options)),
    );
  }

  async #setQueue(options: NativeAudioQueueOptions): Promise<void> {
    for (const item of options.items) {
      this.#rememberDownloadableSource(item.source);
    }

    await this.#queueEngine.setContextQueue({
      songs: options.items.map(queueItemToNativeQueueSong),
      currentIndex: options.index,
      autoplay: false,
    });
    this.#persistPlaybackState();
    this.#emitQueueContentsChanged("queue-edit");
  }

  skipToNext(): Promise<void> {
    return this.#enqueuePlaybackCommand(() =>
      this.#runQueueTransaction(() => this.#skipToNext()),
    );
  }

  async #skipToNext(): Promise<void> {
    if (!this.#hasNativeQueue()) return;
    nativeLogger.debug("skipToNext", "audio-service");
    await this.#queueEngine.skipToNext();
  }

  skipToPrevious(): Promise<void> {
    return this.#enqueuePlaybackCommand(() =>
      this.#runQueueTransaction(() => this.#skipToPrevious()),
    );
  }

  async #skipToPrevious(): Promise<void> {
    if (!this.#hasNativeQueue()) return;
    nativeLogger.debug("skipToPrevious", "audio-service");
    await this.#queueEngine.skipToPrevious(this.#currentTime);
  }

  updateMetadata(metadata: NativeAudioMetadata): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#updateMetadata(metadata));
  }

  async #updateMetadata(metadata: NativeAudioMetadata): Promise<void> {
    try {
      await this.#engine.updateMetadata(this.#normalizeMetadata(metadata));
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  updateRemotePlaybackState(
    options: NativeRemotePlaybackStateOptions,
  ): Promise<void> {
    this.#remotePlaybackState = {
      ...options,
      metadata: { ...options.metadata },
      position: Math.max(0, options.position),
      duration: Math.max(0, options.duration),
      volume:
        typeof options.volume === "number"
          ? clampUnitVolume(options.volume)
          : undefined,
    };
    return Promise.resolve();
  }

  clearRemotePlaybackState(): Promise<void> {
    this.#remotePlaybackState = null;
    return Promise.resolve();
  }

  preload(_options: { source: NativeAudioSource }): Promise<void> {
    return this.notImplemented("preload");
  }

  clear(): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#clear());
  }

  async #clear(): Promise<void> {
    nativeLogger.debug("clear", "audio-service");
    try {
      await this.#engine.clear();
      this.#stopScrobbleTracking();
      this.#cancelSleepTimerInternal();
      this.#requestId = undefined;
      this.#queueRequestSequence = 0;
      this.#queueEngine.clear();
      this.#playbackState = "idle";
      this.#currentTime = 0;
      this.#duration = 0;
      this.#currentSource = null;
      this.#playbackStateStore.clear();
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

  setContextQueue(options: NativeSetContextQueueOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() =>
      this.#runQueueTransaction(() => this.#setContextQueue(options)),
    );
  }

  async #setContextQueue(options: NativeSetContextQueueOptions): Promise<void> {
    nativeLogger.info(
      `setContextQueue songs=${options.songs.length} index=${options.currentIndex}`,
      "audio-service",
    );
    this.#rememberQueueSongs(options.songs);
    if (options.repeatMode) {
      this.#queueEngine.setLoopState(options.repeatMode);
    }
    await this.#queueEngine.setContextQueue(options);
    this.#persistPlaybackState();
    this.#emitQueueContentsChanged("queue-edit");
  }

  updateContextQueue(options: NativeUpdateContextQueueOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() =>
      this.#runQueueTransaction(() => this.#updateContextQueue(options)),
    );
  }

  async #updateContextQueue(
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
    return this.#enqueuePlaybackCommand(() => {
      this.#queueEngine.reorderContextQueue(options.fromIndex, options.toIndex);
      this.#persistPlaybackState();
    });
  }

  addToUserQueue(options: NativeAddToUserQueueOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() => {
      this.#rememberQueueSongs(options.songs);
      this.#queueEngine.addToUserQueue(options.songs, options.position);
      this.#persistPlaybackState();
    });
  }

  removeFromUserQueue(
    options: NativeRemoveFromUserQueueOptions,
  ): Promise<void> {
    return this.#enqueuePlaybackCommand(() => {
      this.#queueEngine.removeFromUserQueue(options.indices);
      this.#persistPlaybackState();
    });
  }

  clearUserQueue(): Promise<void> {
    return this.#enqueuePlaybackCommand(() => {
      this.#queueEngine.clearUserQueue();
      this.#persistPlaybackState();
    });
  }

  playAtIndex(options: NativePlayAtIndexOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() =>
      this.#runQueueTransaction(() =>
        this.#queueEngine.playAtIndex(options.index, options.startTime),
      ),
    );
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

  async #restorePlaybackState(): Promise<void> {
    const state = this.#playbackStateStore.load();
    if (!state) return;

    this.#queueEngine.restoreState(state);
    this.#currentTime = Math.max(0, state.currentTime);
    this.#duration = Math.max(0, state.duration);
    const song = this.#queueEngine.currentSong;
    this.#currentSource = song ? nativeQueueSongToQueueItem(song) : null;
    if (!song) return;

    try {
      await this.#loadQueueSong(song, {
        autoplay: false,
        startTime: this.#currentTime,
      });
    } catch (error) {
      this.#emitFailure(error);
    }
  }

  #persistPlaybackState(): void {
    this.#playbackStateStore.save(
      this.#queueEngine.getFullState({
        currentTime: this.#currentTime,
        duration: this.#duration,
        isPlaying: this.#playbackState === "playing",
      }),
    );
  }

  resolveSongs(options: { ids: string[] }): Promise<NativeResolveSongsResult> {
    const snapshots = new Map<string, Record<string, unknown>>();
    const songs = [
      ...this.#queueEngine.contextSongs,
      ...this.#queueEngine.userQueue,
      ...this.#queueEngine.originalContextSongs,
      ...this.#queueEngine.originalUserSongs,
      ...this.#queueEngine.playedUserQueueHistory,
    ];
    for (const song of songs) {
      if (song.song) snapshots.set(song.id, { ...song.song });
    }

    return Promise.resolve({
      songs: options.ids.flatMap((id) => {
        const song = snapshots.get(id);
        return song ? [song] : [];
      }),
    });
  }

  getScrobbleBuffer(): Promise<NativeScrobbleBufferResult> {
    return Promise.resolve(this.#scrobbleBuffer.getScrobbleBuffer());
  }

  clearScrobbleBuffer(): Promise<void> {
    this.#scrobbleBuffer.clear();
    return Promise.resolve();
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
    options: NativeSetSystemVolumeOptions,
  ): Promise<NativeSystemVolumeResult> {
    return this.#enqueuePlaybackCommand(() => this.#setSystemVolume(options));
  }

  async #setSystemVolume(
    options: NativeSetSystemVolumeOptions,
  ): Promise<NativeSystemVolumeResult> {
    // Desktop keeps the mobile plugin method name for contract parity, but the
    // bridge intentionally adjusts only the mpv/player volume. The user's OS
    // output volume must remain untouched on Electron.
    this.#playerVolume = clampUnitVolume(options.value);
    const result = { volume: this.#playerVolume };
    await this.#engine.setVolume(this.#playerVolume);
    this.#emit("systemVolumeChanged", result);
    return result;
  }

  getSystemVolume(): Promise<NativeSystemVolumeResult> {
    return Promise.resolve({ volume: this.#playerVolume });
  }

  /**
   * Debug-only accessor for the native player debug window. Returns the live
   * libmpv diagnostics and the current buffering flag so the debug snapshot
   * can show engine availability and buffer status without exposing private
   * engine internals through the audio contract.
   */
  getDebugExtras(): {
    isBuffering: boolean;
    diagnostics: DesktopAudioEngineDiagnostics | undefined;
  } {
    return {
      isBuffering: this.#isBuffering,
      diagnostics: this.#engine.getDiagnostics?.(),
    };
  }

  setVolumeHUDEnabled(options: { enabled: boolean }): Promise<void> {
    return this.#systemAudio.setVolumeHUDEnabled(options.enabled);
  }

  setLikeActive(options: { active: boolean }): Promise<void> {
    return this.#systemAudio.setLikeActive(options.active);
  }

  setSleepTimer(options: NativeSetSleepTimerOptions): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#setSleepTimer(options));
  }

  #setSleepTimer(options: NativeSetSleepTimerOptions): void {
    this.#cancelSleepTimerInternal();

    if (options.mode === "endOfTrack") {
      this.#sleepTimerMode = "endOfTrack";
      return;
    }

    const seconds = Math.max(0, options.seconds);
    if (seconds <= 0) return;

    this.#sleepTimerMode = "duration";
    this.#sleepTimerDeadlineMs = Date.now() + seconds * 1_000;
    this.#sleepTimerHandle = setTimeout(() => {
      this.#enqueuePlaybackCommand(() =>
        this.#fireSleepTimer("duration"),
      ).catch((error) => this.#emitFailure(error));
    }, seconds * 1_000);
  }

  cancelSleepTimer(): Promise<void> {
    return this.#enqueuePlaybackCommand(() => this.#cancelSleepTimerInternal());
  }

  getSleepTimerRemaining(): Promise<NativeSleepTimerRemainingResult> {
    return Promise.resolve({
      remainingSeconds:
        this.#sleepTimerDeadlineMs > 0
          ? Math.max(0, (this.#sleepTimerDeadlineMs - Date.now()) / 1_000)
          : 0,
    });
  }

  onEvent(listener: NativeAudioServiceEventListener): () => void {
    this.#listeners.add(listener);
    this.#replayStartupAvailabilityError(listener);

    return () => {
      this.#listeners.delete(listener);
    };
  }

  destroy(): Promise<void> | void {
    this.#unsubscribeFromEngine();
    this.#listeners.clear();
    this.#downloadManager.cancelAll();
    this.#cancelSleepTimerInternal();
    const engineDestroyed = this.#engine.destroy?.();
    const systemDestroyed = this.#systemAudio.destroy?.();

    if (engineDestroyed || systemDestroyed) {
      return Promise.all([engineDestroyed, systemDestroyed]).then(() => {});
    }
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

  handleRemoteCommand(command: NativeAudioRemoteCommand): Promise<boolean> {
    return this.#enqueuePlaybackCommand(() =>
      this.#handleRemoteCommand(command),
    );
  }

  async #handleRemoteCommand(
    command: NativeAudioRemoteCommand,
  ): Promise<boolean> {
    if (this.#emitRemoteControlCommandForNativeCommand(command)) {
      return true;
    }

    switch (command) {
      case "play":
        if (!this.#currentSource) return false;
        await this.#play();
        return true;
      case "pause":
        if (!this.#currentSource) return false;
        await this.#pause();
        return true;
      case "togglePlayPause":
        if (!this.#currentSource) return false;
        if (this.#playbackState === "playing") {
          await this.#pause();
        } else {
          await this.#play();
        }
        return true;
      case "next":
        if (!this.getControlState().hasNext) return false;
        await this.#runQueueTransaction(() => this.#skipToNext());
        return true;
      case "previous":
        if (!this.getControlState().hasPrevious) return false;
        await this.#runQueueTransaction(() => this.#skipToPrevious());
        return true;
      default:
        return false;
    }
  }

  emitRemoteCommand(
    command: NativeAudioRemoteCommand,
    options: { position?: number } = {},
  ): void {
    if (
      this.#emitRemoteControlCommandForNativeCommand(command, options.position)
    ) {
      return;
    }

    this.#emit("remoteCommand", {
      requestId: this.#requestId,
      command,
      ...(typeof options.position === "number"
        ? { position: options.position }
        : {}),
    });
  }

  // System media commands arrive from the native playback backend (macOS
  // Control Center / Now Playing scrubber and media keys, remote command
  // centers on other platforms). Apply them directly to local playback instead
  // of round-tripping through the renderer, so a seek from the system scrubber
  // actually moves playback (the previous main-process -> renderer ->
  // main-process round-trip left it with no effect). The renderer stays in sync
  // via the playback/progress events emitted below. When projecting to a
  // remote device, forward the command there instead of acting locally.
  async #handleSystemMediaCommand(
    command: NativeAudioRemoteCommand,
    position?: number,
  ): Promise<void> {
    if (this.#emitRemoteControlCommandForNativeCommand(command, position)) {
      return;
    }

    switch (command) {
      case "seek":
        if (typeof position === "number" && Number.isFinite(position)) {
          await this.#seek({ position: Math.max(0, position) });
        }
        return;
      case "play":
      case "pause":
      case "togglePlayPause":
      case "next":
      case "previous":
        await this.#handleRemoteCommand(command);
        return;
      case "like":
      case "shuffle":
        // Star/shuffle state is owned by the renderer; forward so the UI
        // remains the source of truth for those toggles.
        this.emitRemoteCommand(command, {});
        return;
    }
  }

  emitRemoteControlCommand(
    command: NativeRemoteControlCommandEvent["command"],
    options: {
      targetDeviceId?: string;
      expectedGeneration?: number;
      handledNatively?: boolean;
    } = {},
  ): void {
    this.#emit("remoteControlCommand", {
      requestId: this.#requestId,
      targetDeviceId:
        options.targetDeviceId ?? this.#remotePlaybackState?.targetDeviceId,
      expectedGeneration:
        options.expectedGeneration ??
        this.#remotePlaybackState?.expectedGeneration,
      handledNatively: options.handledNatively ?? false,
      command,
    });
  }

  #handleEngineEvent(event: DesktopAudioEngineEvent): void {
    switch (event.type) {
      case "playbackStateChanged":
        this.#playbackState = event.state;
        this.#syncScrobbleTrackingWithPlaybackState(event.state);
        this.#emit("playbackStateChanged", {
          requestId: this.#requestId,
          state: event.state,
        });
        break;
      case "progress":
        this.#currentTime = event.currentTime;
        this.#duration = event.duration;
        this.#persistPlaybackState();
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
        this.#isBuffering = event.isBuffering;
        nativeLogger.debug(
          `buffering ${event.isBuffering ? "started" : "ended"}`,
          "audio-service",
        );
        this.#emit("bufferingChanged", {
          requestId: this.#requestId,
          isBuffering: event.isBuffering,
        });
        break;
      case "ended":
        nativeLogger.info(
          `ended reason=${event.reason ?? "unknown"}`,
          "audio-service",
        );
        this.#enqueuePlaybackCommand(() =>
          this.#runQueueTransaction(() => this.#handlePlaybackEnded(event)),
        ).catch((error) => this.#emitFailure(error));
        break;
      case "error":
        nativeLogger.error(
          `engine error: ${event.code ?? ""} ${event.message}`,
          "audio-service",
        );
        this.#emit("error", {
          requestId: this.#requestId,
          code: event.code,
          message: event.message,
        });
        break;
      case "systemMediaCommand":
        this.#enqueuePlaybackCommand(() =>
          this.#handleSystemMediaCommand(event.command, event.position),
        ).catch((error) => this.#emitFailure(error));
        break;
    }
  }

  #emitFailure(error: unknown): void {
    this.#playbackState = "failed";
    nativeLogger.error(
      `playback failed: ${error instanceof Error ? error.message : String(error)}`,
      "audio-service",
    );
    this.#emit("playbackStateChanged", {
      requestId: this.#requestId,
      state: "failed",
    });
    this.#emit("error", {
      requestId: this.#requestId,
      ...toNativeAudioErrorEvent(error),
    });
  }

  // The renderer addresses cover art through the `aonsoku-media://` custom
  // protocol (or, for queue-driven loads, a bare cover-art id), but the native
  // macOS/Linux system media session downloads artwork with platform HTTP
  // stacks (NSURLSession / D-Bus clients) that cannot resolve that scheme.
  // Normalize the artwork reference into an authenticated Subsonic HTTP URL
  // before handing metadata to the playback engine so the system media session
  // can fetch it. Falls back to the original value when no resolver is wired.
  #normalizeMetadata(
    metadata: NativeAudioMetadata | undefined,
  ): NativeAudioMetadata | undefined {
    if (!metadata) return metadata;
    const resolved = this.#resolveArtworkUrl(metadata.artworkUrl);
    if (resolved === metadata.artworkUrl) return metadata;
    return { ...metadata, artworkUrl: resolved };
  }

  #resolveArtworkUrl(artworkUrl: string | undefined): string | undefined {
    if (!artworkUrl) return artworkUrl;
    try {
      return this.#artworkUrlResolver(artworkUrl);
    } catch {
      return undefined;
    }
  }

  #scheduleStartupAvailabilityCheck(): void {
    const diagnostics = this.#engine.getDiagnostics?.();
    if (diagnostics?.status === "unavailable") {
      this.#startupAvailabilityError = startupErrorFromDiagnostics(diagnostics);
      return;
    }

    this.#engine
      .checkAvailability?.()
      .then((result) => {
        if (result.status === "unavailable") {
          this.#setStartupAvailabilityError(
            startupErrorFromDiagnostics(result),
          );
        }
      })
      .catch((error) => {
        this.#setStartupAvailabilityError(startupErrorFromCheckFailure(error));
      });
  }

  #setStartupAvailabilityError(
    event: Omit<NativeAudioEvents["error"], "requestId">,
  ): void {
    this.#startupAvailabilityError = event;
    this.#emit("error", event);
  }

  #replayStartupAvailabilityError(
    listener: NativeAudioServiceEventListener,
  ): void {
    const event = this.#startupAvailabilityError;
    if (!event) return;

    queueMicrotask(() => {
      if (!this.#listeners.has(listener)) return;

      listener({
        eventName: "error",
        event,
      });
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

  #startScrobbleTrackingForLoad(options: NativeAudioLoadOptions): void {
    const songId = getScrobbleSongId(options.source);
    if (!songId) return;

    this.#scrobbleBuffer.startTracking(
      songId,
      Boolean(options.autoplay) || this.#playbackState === "playing",
    );
  }

  #startScrobbleTrackingForSong(song: NativeQueueSong): void {
    this.#scrobbleBuffer.startTracking(song.id, true);
  }

  #stopScrobbleTracking(): void {
    this.#scrobbleBuffer.stopTracking();
  }

  #syncScrobbleTrackingWithPlaybackState(
    state: NativeAudioEvents["playbackStateChanged"]["state"],
  ): void {
    if (state === "playing") {
      this.#scrobbleBuffer.resumeTracking();
      return;
    }

    if (state === "ended") {
      this.#stopScrobbleTracking();
      return;
    }

    if (
      state === "paused" ||
      state === "stopped" ||
      state === "idle" ||
      state === "failed"
    ) {
      this.#scrobbleBuffer.pauseTracking();
    }
  }

  #cancelSleepTimerInternal(): void {
    if (this.#sleepTimerHandle) {
      clearTimeout(this.#sleepTimerHandle);
    }

    this.#sleepTimerHandle = null;
    this.#sleepTimerDeadlineMs = 0;
    this.#sleepTimerMode = "duration";
  }

  async #fireSleepTimer(
    reason: NativeAudioEvents["sleepTimerFired"]["reason"],
  ): Promise<void> {
    await this.#pause();
    this.#cancelSleepTimerInternal();
    this.#playbackState = "paused";
    this.#emit("playbackStateChanged", {
      requestId: this.#requestId,
      state: "paused",
    });
    this.#emit("sleepTimerFired", {
      reason,
    });
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

  #emitRemoteControlCommandForNativeCommand(
    command: NativeAudioRemoteCommand,
    position?: number,
  ): boolean {
    const remoteCommand = this.#buildRemoteControlCommand(command, position);
    if (!remoteCommand) return false;

    this.emitRemoteControlCommand(remoteCommand);
    return true;
  }

  #buildRemoteControlCommand(
    command: NativeAudioRemoteCommand,
    position?: number,
  ): NativeRemoteControlCommandEvent["command"] | null {
    const projection = this.#remotePlaybackState;
    if (!projection) return null;

    switch (command) {
      case "play":
        return { type: "play" };
      case "pause":
        return { type: "pause" };
      case "togglePlayPause":
        return { type: "toggle_play_pause" };
      case "next":
        return { type: "next" };
      case "previous":
        return { type: "previous" };
      case "seek":
        return typeof position === "number" && Number.isFinite(position)
          ? { type: "seek", seconds: Math.max(0, position) }
          : null;
      case "shuffle":
        return {
          type: "set_shuffle",
          enabled: !projection.isShuffleActive,
        };
      case "like":
        return { type: "toggle_like" };
    }
  }

  #enqueuePlaybackCommand<T>(command: () => T | Promise<T>): Promise<T> {
    const result = this.#playbackCommandTail.then(command, command);
    this.#playbackCommandTail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  async #runQueueTransaction<T>(command: () => T | Promise<T>): Promise<T> {
    // DesktopQueueEngine selects/removes queue entries before awaiting the
    // delegate load. If libmpv rejects that load, keep the previously committed
    // queue/source as truth and overwrite any progress-triggered speculative
    // persistence before the FIFO proceeds to the next command.
    const queueState = this.#queueEngine.getFullState({
      currentTime: this.#currentTime,
      duration: this.#duration,
      isPlaying: this.#playbackState === "playing",
    });
    const requestId = this.#requestId;
    const currentSource = this.#currentSource;
    const currentTime = this.#currentTime;
    const duration = this.#duration;

    try {
      return await command();
    } catch (error) {
      this.#queueEngine.restoreState(queueState);
      this.#queueEngine.isRestored = queueState.isRestored;
      this.#requestId = requestId;
      this.#currentSource = currentSource;
      this.#currentTime = currentTime;
      this.#duration = duration;
      this.#persistPlaybackState();
      throw error;
    }
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

    await this.#load({
      requestId: `desktop-native-queue-${++this.#queueRequestSequence}`,
      source: item.source,
      metadata: item.metadata,
      autoplay: options.autoplay,
      startTime: options.startTime,
    });
  }

  async #seekQueueSongToStart(song: NativeQueueSong): Promise<void> {
    this.#stopScrobbleTracking();
    this.#currentTime = 0;
    await this.#seek({ position: 0 });
    await this.#play();
    this.#startScrobbleTrackingForSong(song);
  }

  async #handleQueueExhausted(): Promise<void> {
    try {
      this.#stopScrobbleTracking();
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
    if (this.#sleepTimerMode === "endOfTrack") {
      await this.#fireSleepTimer("endOfTrack");
      return;
    }

    if (this.#hasNativeQueue()) {
      await this.#queueEngine.handleEnded();
      return;
    }

    this.#playbackState = "ended";
    this.#stopScrobbleTracking();
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

function startupErrorFromDiagnostics(
  diagnostics: Extract<
    DesktopAudioEngineDiagnostics,
    { status: "unavailable" }
  >,
): Omit<NativeAudioEvents["error"], "requestId"> {
  return {
    code: diagnostics.code,
    message: diagnostics.message,
  };
}

function startupErrorFromCheckFailure(
  error: unknown,
): Omit<NativeAudioEvents["error"], "requestId"> {
  const event = toNativeAudioErrorEvent(error);

  return {
    code: event.code ?? "libmpv-unavailable",
    message: `Desktop native audio startup check failed: ${event.message}`,
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

function getScrobbleSongId(source: NativeAudioSource): string | null {
  switch (source.kind) {
    case "stream":
    case "blob":
    case "native-file":
      return source.songId ?? null;
    case "radio":
      return null;
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

function clampUnitVolume(value: number): number {
  if (!Number.isFinite(value)) return 1;
  return Math.max(0, Math.min(1, value));
}
