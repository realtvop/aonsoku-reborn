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
  NativeAudioQueueOptions,
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
}

export class NativeAudioService implements AonsokuAudioApi {
  readonly #engine: DesktopAudioEngine;
  readonly #listeners = new Set<NativeAudioServiceEventListener>();
  #requestId: string | undefined;

  constructor(options: NativeAudioServiceOptions = {}) {
    this.#engine = options.engine ?? new MpvAudioEngine();
    this.#engine.onEvent((event) => this.#handleEngineEvent(event));
  }

  async load(options: NativeAudioLoadOptions): Promise<void> {
    this.#requestId = options.requestId;

    try {
      await this.#engine.load({
        source: resolveNativeAudioSource(options.source),
        metadata: options.metadata,
        autoplay: options.autoplay,
        startTime: options.startTime,
      });
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
    return this.notImplemented("setRepeatMode");
  }

  setShuffle(_options: NativeAudioShuffleOptions): Promise<void> {
    return this.notImplemented("setShuffle");
  }

  markAsShuffled(_options: NativeMarkAsShuffledOptions): Promise<void> {
    return this.notImplemented("markAsShuffled");
  }

  setQueue(_options: NativeAudioQueueOptions): Promise<void> {
    return this.notImplemented("setQueue");
  }

  skipToNext(): Promise<void> {
    return this.notImplemented("skipToNext");
  }

  skipToPrevious(): Promise<void> {
    return this.notImplemented("skipToPrevious");
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
    } catch (error) {
      this.#emitFailure(error);
      throw error;
    }
  }

  storeAudioFile(
    _options: NativeAudioStoreFileOptions,
  ): Promise<NativeAudioCachedAudioFile> {
    return this.notImplemented("storeAudioFile");
  }

  resolveAudioFile(
    _options: NativeAudioFileOptions,
  ): Promise<NativeAudioResolveFileResult> {
    return this.notImplemented("resolveAudioFile");
  }

  getAudioFileSize(
    _options: NativeAudioFileOptions,
  ): Promise<NativeAudioFileSizeResult> {
    return this.notImplemented("getAudioFileSize");
  }

  deleteAudioFile(
    _options: NativeAudioFileOptions,
  ): Promise<NativeAudioDeleteFileResult> {
    return this.notImplemented("deleteAudioFile");
  }

  clearAudioFiles(): Promise<NativeAudioClearFilesResult> {
    return this.notImplemented("clearAudioFiles");
  }

  setContextQueue(_options: NativeSetContextQueueOptions): Promise<void> {
    return this.notImplemented("setContextQueue");
  }

  updateContextQueue(_options: NativeUpdateContextQueueOptions): Promise<void> {
    return this.notImplemented("updateContextQueue");
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
    return this.notImplemented("getFullState");
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

  downloadAudioFile(_options: NativeDownloadAudioFileOptions): Promise<void> {
    return this.notImplemented("downloadAudioFile");
  }

  cancelDownload(_options?: NativeCancelDownloadOptions): Promise<void> {
    return this.notImplemented("cancelDownload");
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
    return this.notImplemented("setVolumeHUDEnabled");
  }

  setLikeActive(_options: { active: boolean }): Promise<void> {
    return this.notImplemented("setLikeActive");
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
    return this.#engine.destroy?.();
  }

  #handleEngineEvent(event: DesktopAudioEngineEvent): void {
    switch (event.type) {
      case "playbackStateChanged":
        this.#emit("playbackStateChanged", {
          requestId: this.#requestId,
          state: event.state,
        });
        break;
      case "progress":
        this.#emit("progress", {
          requestId: this.#requestId,
          currentTime: event.currentTime,
          duration: event.duration,
          bufferedTime: event.bufferedTime,
        });
        break;
      case "durationChanged":
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

  private notImplemented<T>(method: keyof AonsokuAudioApi): Promise<T> {
    return Promise.reject(new DesktopNativeAudioNotImplementedError(method));
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
