import { WebPlugin } from "@capacitor/core";
import type {
  AonsokuNativeAudioPlugin,
  NativeAddToUserQueueOptions,
  NativeAudioFileOptions,
  NativeAudioLoadOptions,
  NativeAudioMetadata,
  NativeAudioQueueOptions,
  NativeAudioRepeatModeOptions,
  NativeAudioSeekOptions,
  NativeAudioShuffleOptions,
  NativeAudioSource,
  NativeAudioStoreFileOptions,
  NativeMarkAsShuffledOptions,
  NativePlayAtIndexOptions,
  NativeRemotePlaybackStateOptions,
  NativeRemoveFromUserQueueOptions,
  NativeReorderContextQueueOptions,
  NativeSetContextQueueOptions,
  NativeSetSystemVolumeOptions,
  NativeUpdateContextQueueOptions,
} from "./definitions";
import { NATIVE_AUDIO_PLUGIN_NAME } from "./definitions";

export function createNativeAudioUnavailableError(method: string) {
  return new Error(
    `${NATIVE_AUDIO_PLUGIN_NAME}.${method} is only available on native Capacitor platforms.`,
  );
}

export class AonsokuNativeAudioWeb
  extends WebPlugin
  implements AonsokuNativeAudioPlugin
{
  load(_options: NativeAudioLoadOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("load"));
  }

  play(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("play"));
  }

  pause(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("pause"));
  }

  stop(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("stop"));
  }

  seek(_options: NativeAudioSeekOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("seek"));
  }

  setRepeatMode(_options: NativeAudioRepeatModeOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setRepeatMode"));
  }

  setShuffle(_options: NativeAudioShuffleOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setShuffle"));
  }

  markAsShuffled(_options: NativeMarkAsShuffledOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("markAsShuffled"));
  }

  setQueue(_options: NativeAudioQueueOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setQueue"));
  }

  skipToNext(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("skipToNext"));
  }

  skipToPrevious(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("skipToPrevious"));
  }

  updateMetadata(_metadata: NativeAudioMetadata): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("updateMetadata"));
  }

  updateRemotePlaybackState(
    _options: NativeRemotePlaybackStateOptions,
  ): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("updateRemotePlaybackState"),
    );
  }

  clearRemotePlaybackState(): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("clearRemotePlaybackState"),
    );
  }

  preload(_options: { source: NativeAudioSource }): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("preload"));
  }

  clear(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("clear"));
  }

  storeAudioFile(_options: NativeAudioStoreFileOptions) {
    return Promise.reject(createNativeAudioUnavailableError("storeAudioFile"));
  }

  resolveAudioFile(_options: NativeAudioFileOptions) {
    return Promise.reject(
      createNativeAudioUnavailableError("resolveAudioFile"),
    );
  }

  getAudioFileSize(_options: NativeAudioFileOptions) {
    return Promise.reject(
      createNativeAudioUnavailableError("getAudioFileSize"),
    );
  }

  deleteAudioFile(_options: NativeAudioFileOptions) {
    return Promise.reject(createNativeAudioUnavailableError("deleteAudioFile"));
  }

  clearAudioFiles() {
    return Promise.reject(createNativeAudioUnavailableError("clearAudioFiles"));
  }

  setContextQueue(_options: NativeSetContextQueueOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("setContextQueue"));
  }

  updateContextQueue(_options: NativeUpdateContextQueueOptions): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("updateContextQueue"),
    );
  }

  reorderContextQueue(
    _options: NativeReorderContextQueueOptions,
  ): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("reorderContextQueue"),
    );
  }

  addToUserQueue(_options: NativeAddToUserQueueOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("addToUserQueue"));
  }

  removeFromUserQueue(
    _options: NativeRemoveFromUserQueueOptions,
  ): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("removeFromUserQueue"),
    );
  }

  clearUserQueue(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("clearUserQueue"));
  }

  playAtIndex(_options: NativePlayAtIndexOptions): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("playAtIndex"));
  }

  resolveSongs() {
    return Promise.reject(createNativeAudioUnavailableError("resolveSongs"));
  }

  getFullState() {
    return Promise.reject(createNativeAudioUnavailableError("getFullState"));
  }

  getScrobbleBuffer() {
    return Promise.reject(
      createNativeAudioUnavailableError("getScrobbleBuffer"),
    );
  }

  clearScrobbleBuffer(): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("clearScrobbleBuffer"),
    );
  }

  downloadAudioFile(): Promise<void> {
    return Promise.reject(
      createNativeAudioUnavailableError("downloadAudioFile"),
    );
  }

  cancelDownload(): Promise<void> {
    return Promise.reject(createNativeAudioUnavailableError("cancelDownload"));
  }

  setSystemVolume(_options: NativeSetSystemVolumeOptions) {
    return Promise.reject(createNativeAudioUnavailableError("setSystemVolume"));
  }

  getSystemVolume() {
    return Promise.reject(createNativeAudioUnavailableError("getSystemVolume"));
  }

  setVolumeHUDEnabled(_options: { enabled: boolean }) {
    return Promise.resolve();
  }

  setLikeActive(_options: { active: boolean }) {
    return Promise.resolve();
  }

  setSleepTimer() {
    return Promise.reject(createNativeAudioUnavailableError("setSleepTimer"));
  }

  cancelSleepTimer() {
    return Promise.reject(
      createNativeAudioUnavailableError("cancelSleepTimer"),
    );
  }

  getSleepTimerRemaining() {
    return Promise.reject(
      createNativeAudioUnavailableError("getSleepTimerRemaining"),
    );
  }
}
