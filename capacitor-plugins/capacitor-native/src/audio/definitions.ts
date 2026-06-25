import type { Plugin, PluginListenerHandle } from "@capacitor/core";

export const NATIVE_AUDIO_PLUGIN_NAME = "AonsokuNativeAudio";

export type NativeAudioSource =
  | {
      kind: "stream";
      url: string;
      songId?: string;
    }
  | {
      kind: "blob";
      url: string;
      songId?: string;
    }
  | {
      kind: "native-file";
      uri: string;
      songId?: string;
    }
  | {
      kind: "radio";
      url: string;
      radioId?: string;
    };

export interface NativeAudioMetadata {
  title?: string;
  artist?: string;
  album?: string;
  duration?: number;
  artworkUrl?: string;
}

export interface NativeRemotePlaybackStateOptions {
  metadata: NativeAudioMetadata;
  isPlaying: boolean;
  position: number;
  duration: number;
}

export interface NativeAudioLoadOptions {
  source: NativeAudioSource;
  metadata?: NativeAudioMetadata;
  autoplay?: boolean;
  startTime?: number;
  requestId?: string;
}

export interface NativeAudioSeekOptions {
  position: number;
}

export interface NativeAudioRepeatModeOptions {
  mode: "off" | "one" | "all";
}

export interface NativeAudioShuffleOptions {
  enabled: boolean;
}

export interface NativeAudioQueueItem {
  source: NativeAudioSource;
  metadata?: NativeAudioMetadata;
}

export interface NativeAudioQueueOptions {
  items: NativeAudioQueueItem[];
  index: number;
}

export interface NativeAudioCachedAudioFile {
  songId: string;
  uri: string;
  contentType?: string;
  sizeBytes?: number;
  lastModifiedAt?: number;
}

export interface NativeAudioStoreFileOptions {
  songId: string;
  dataBase64: string;
  contentType: string;
}

export interface NativeAudioFileOptions {
  songId: string;
}

export interface NativeAudioResolveFileResult {
  file: NativeAudioCachedAudioFile | null;
}

export interface NativeAudioFileSizeResult {
  sizeBytes: number | null;
}

export interface NativeAudioDeleteFileResult {
  deleted: boolean;
}

export interface NativeAudioClearFilesResult {
  deletedCount: number;
}

// --- Native Queue Control Types ---

export interface NativeQueueSong {
  id: string;
  title: string;
  artist: string;
  artistId?: string;
  album: string;
  albumId?: string;
  duration: number;
  coverArtId?: string;
  streamUrl: string;
  cachedFileUri?: string;
}

export interface NativeSetContextQueueOptions {
  songs: NativeQueueSong[];
  currentIndex: number;
  sourceId?: NativeQueueSourceId | null;
  sourceName?: string | null;
  autoplay?: boolean;
  startTime?: number;
  repeatMode?: "off" | "one" | "all";
}

export type NativeQueueSourceId =
  | { type: "album"; id: string }
  | { type: "playlist"; id: string }
  | { type: "radio"; id: string }
  | { type: "artist"; id: string }
  | { type: "genre"; id: string };

export interface NativeAddToUserQueueOptions {
  songs: NativeQueueSong[];
  position: "next" | "last";
}

export interface NativeRemoveFromUserQueueOptions {
  indices: number[];
}

export interface NativePlayAtIndexOptions {
  index: number;
  startTime?: number;
}

export interface NativeUpdateContextQueueOptions {
  songs: NativeQueueSong[];
  currentIndex: number;
}

export interface NativeReorderContextQueueOptions {
  fromIndex: number;
  toIndex: number;
}

export interface NativeFullState {
  contextQueue: {
    songs: NativeQueueSong[];
    currentIndex: number;
    sourceId: NativeQueueSourceId | null;
    sourceName: string | null;
  };
  userQueue: NativeQueueSong[];
  originalContextSongs: NativeQueueSong[];
  originalUserSongs: NativeQueueSong[];
  isInUserQueue: boolean;
  isShuffleActive: boolean;
  loopState: "off" | "one" | "all";
  isPlaying: boolean;
  currentTime: number;
  duration: number;
  currentSongId: string | null;
}

export interface NativeScrobbleEntry {
  songId: string;
  playedDurationMs: number;
  timestamp: number;
}

export interface NativeScrobbleBufferResult {
  entries: NativeScrobbleEntry[];
}

// --- Native Queue Control Events ---

export interface NativeAudioQueueStateChangedEvent {
  requestId?: string;
  currentIndex: number;
  songId: string;
  reason: "next" | "previous" | "ended" | "skip";
  isInUserQueue: boolean;
}

export interface NativeAudioQueueContentsChangedEvent {
  requestId?: string;
  reason: "shuffle" | "unshuffle" | "user-queue-consumed" | "queue-edit";
}

export interface NativeAudioScrobbleEvent {
  songId: string;
  playedDurationMs: number;
  timestamp: number;
}

export interface NativeAudioPlaybackStateChangedEvent {
  requestId?: string;
  state:
    | "idle"
    | "loading"
    | "playing"
    | "paused"
    | "stopped"
    | "ended"
    | "failed";
}

export interface NativeAudioProgressEvent {
  requestId?: string;
  currentTime: number;
  duration: number;
  bufferedTime?: number;
}

export interface NativeAudioDurationChangedEvent {
  requestId?: string;
  duration: number;
}

export interface NativeAudioBufferingChangedEvent {
  requestId?: string;
  isBuffering: boolean;
}

export interface NativeAudioEndedEvent {
  requestId?: string;
  reason?: "finished" | "stopped";
}

export interface NativeAudioErrorEvent {
  requestId?: string;
  code?: string;
  message: string;
}

export type NativeAudioRemoteCommand =
  | "play"
  | "pause"
  | "togglePlayPause"
  | "next"
  | "previous"
  | "seek"
  | "like"
  | "shuffle";

export interface NativeAudioRemoteCommandEvent {
  requestId?: string;
  command: NativeAudioRemoteCommand;
  position?: number;
}

export interface NativeAudioInterruptionChangedEvent {
  requestId?: string;
  type: "began" | "ended";
  shouldResume?: boolean;
}

export interface NativeAudioRouteChangedEvent {
  requestId?: string;
  reason?: string;
}

export interface NativeDownloadAudioFileOptions {
  songId: string;
  maxBitRate?: number;
  format?: string;
}

export interface NativeCancelDownloadOptions {
  songId?: string;
}

export interface NativeDownloadProgressEvent {
  songId: string;
  loaded: number;
  total: number;
}

export interface NativeDownloadCompletedEvent {
  songId: string;
  uri: string;
  contentType: string;
  sizeBytes: number;
}

export interface NativeDownloadFailedEvent {
  songId: string;
  error: string;
}

export interface NativeStreamCacheCompletedEvent {
  songId: string;
  uri: string;
  contentType: string;
  sizeBytes: number;
}

export interface NativeAudioBufferCompleteEvent {
  requestId?: string;
  songId: string;
}

export interface NativeSetSystemVolumeOptions {
  value: number;
}

export interface NativeSystemVolumeResult {
  volume: number;
}

export interface NativeSystemVolumeChangedEvent {
  volume: number;
}

export interface NativeSleepTimerFiredEvent {
  reason: "duration" | "endOfTrack";
}

export interface NativeSleepTimerRemainingResult {
  remainingSeconds: number;
}

export interface NativeSetSleepTimerOptions {
  seconds: number;
  mode: "duration" | "endOfTrack";
}

export interface NativeResolveSongsResult {
  songs: Record<string, unknown>[];
}

export interface NativeMarkAsShuffledOptions {
  originalSongs: NativeQueueSong[];
}

export interface NativeAudioEvents {
  playbackStateChanged: NativeAudioPlaybackStateChangedEvent;
  progress: NativeAudioProgressEvent;
  durationChanged: NativeAudioDurationChangedEvent;
  bufferingChanged: NativeAudioBufferingChangedEvent;
  ended: NativeAudioEndedEvent;
  error: NativeAudioErrorEvent;
  remoteCommand: NativeAudioRemoteCommandEvent;
  interruptionChanged: NativeAudioInterruptionChangedEvent;
  routeChanged: NativeAudioRouteChangedEvent;
  queueStateChanged: NativeAudioQueueStateChangedEvent;
  queueContentsChanged: NativeAudioQueueContentsChangedEvent;
  scrobbleEvent: NativeAudioScrobbleEvent;
  downloadProgress: NativeDownloadProgressEvent;
  downloadCompleted: NativeDownloadCompletedEvent;
  downloadFailed: NativeDownloadFailedEvent;
  streamCacheCompleted: NativeStreamCacheCompletedEvent;
  bufferComplete: NativeAudioBufferCompleteEvent;
  systemVolumeChanged: NativeSystemVolumeChangedEvent;
  sleepTimerFired: NativeSleepTimerFiredEvent;
}

export type NativeAudioEventName = keyof NativeAudioEvents;

export interface AonsokuNativeAudioPlugin extends Plugin {
  load(options: NativeAudioLoadOptions): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  stop(): Promise<void>;
  seek(options: NativeAudioSeekOptions): Promise<void>;
  setRepeatMode(options: NativeAudioRepeatModeOptions): Promise<void>;
  setShuffle(options: NativeAudioShuffleOptions): Promise<void>;
  markAsShuffled(options: NativeMarkAsShuffledOptions): Promise<void>;
  setQueue(options: NativeAudioQueueOptions): Promise<void>;
  skipToNext(): Promise<void>;
  skipToPrevious(): Promise<void>;
  updateMetadata(metadata: NativeAudioMetadata): Promise<void>;
  updateRemotePlaybackState(
    options: NativeRemotePlaybackStateOptions,
  ): Promise<void>;
  clearRemotePlaybackState(): Promise<void>;
  preload(options: { source: NativeAudioSource }): Promise<void>;
  clear(): Promise<void>;
  storeAudioFile(
    options: NativeAudioStoreFileOptions,
  ): Promise<NativeAudioCachedAudioFile>;
  resolveAudioFile(
    options: NativeAudioFileOptions,
  ): Promise<NativeAudioResolveFileResult>;
  getAudioFileSize(
    options: NativeAudioFileOptions,
  ): Promise<NativeAudioFileSizeResult>;
  deleteAudioFile(
    options: NativeAudioFileOptions,
  ): Promise<NativeAudioDeleteFileResult>;
  clearAudioFiles(): Promise<NativeAudioClearFilesResult>;

  // Native Queue Control
  setContextQueue(options: NativeSetContextQueueOptions): Promise<void>;
  updateContextQueue(options: NativeUpdateContextQueueOptions): Promise<void>;
  reorderContextQueue(options: NativeReorderContextQueueOptions): Promise<void>;
  addToUserQueue(options: NativeAddToUserQueueOptions): Promise<void>;
  removeFromUserQueue(options: NativeRemoveFromUserQueueOptions): Promise<void>;
  clearUserQueue(): Promise<void>;
  playAtIndex(options: NativePlayAtIndexOptions): Promise<void>;
  getFullState(): Promise<NativeFullState>;
  getScrobbleBuffer(): Promise<NativeScrobbleBufferResult>;
  clearScrobbleBuffer(): Promise<void>;

  // Native Audio Download
  downloadAudioFile(options: NativeDownloadAudioFileOptions): Promise<void>;
  cancelDownload(options?: NativeCancelDownloadOptions): Promise<void>;

  // System Volume Control
  setSystemVolume(
    options: NativeSetSystemVolumeOptions,
  ): Promise<NativeSystemVolumeResult>;
  getSystemVolume(): Promise<NativeSystemVolumeResult>;
  setVolumeHUDEnabled(options: { enabled: boolean }): Promise<void>;
  setLikeActive(options: { active: boolean }): Promise<void>;

  // Song Resolution
  resolveSongs(options: { ids: string[] }): Promise<NativeResolveSongsResult>;

  // Sleep Timer
  setSleepTimer(options: NativeSetSleepTimerOptions): Promise<void>;
  cancelSleepTimer(): Promise<void>;
  getSleepTimerRemaining(): Promise<NativeSleepTimerRemainingResult>;

  addListener<TEvent extends NativeAudioEventName>(
    eventName: TEvent,
    listenerFunc: (event: NativeAudioEvents[TEvent]) => void,
  ): Promise<PluginListenerHandle>;
}
