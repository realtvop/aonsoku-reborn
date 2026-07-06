import type {
  AonsokuAudioApi,
  NativeAudioCachedAudioFile,
  NativeAudioClearFilesResult,
  NativeAudioDeleteFileResult,
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

export class DesktopNativeAudioNotImplementedError extends Error {
  constructor(method: keyof AonsokuAudioApi) {
    super(`Desktop native audio bridge method ${method} is not implemented.`);
    this.name = "DesktopNativeAudioNotImplementedError";
  }
}

export class DesktopNativeAudioService implements AonsokuAudioApi {
  load(_options: NativeAudioLoadOptions): Promise<void> {
    return this.notImplemented("load");
  }

  play(): Promise<void> {
    return this.notImplemented("play");
  }

  pause(): Promise<void> {
    return this.notImplemented("pause");
  }

  stop(): Promise<void> {
    return this.notImplemented("stop");
  }

  seek(_options: NativeAudioSeekOptions): Promise<void> {
    return this.notImplemented("seek");
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

  updateMetadata(_metadata: NativeAudioMetadata): Promise<void> {
    return this.notImplemented("updateMetadata");
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

  clear(): Promise<void> {
    return this.notImplemented("clear");
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

  private notImplemented<T>(method: keyof AonsokuAudioApi): Promise<T> {
    return Promise.reject(new DesktopNativeAudioNotImplementedError(method));
  }
}
