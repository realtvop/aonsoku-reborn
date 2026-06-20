import {
  CurrentSongData,
  LanControlMessageType,
  PlayerStateData,
  QueueData,
  RemoteDeviceInfo,
} from "./lanControl";
import { Radio } from "./responses/radios";
import { ISong } from "./responses/song";

export enum LoopState {
  Off = 0,
  All = 1,
  One = 2,
}

export type QueueSourceId =
  | { type: "album"; id: string }
  | { type: "playlist"; id: string }
  | { type: "radio"; id: string }
  | { type: "artist"; id: string }
  | { type: "genre"; id: string }
  | null;

export interface IContextQueue {
  songs: ISong[];
  currentIndex: number;
  sourceId: QueueSourceId;
  sourceName: string | null;
}

export interface IUserQueue {
  songs: ISong[];
}

export interface ISongList {
  sourceQueue: IContextQueue;
  contextQueue: IContextQueue;
  userQueue: IUserQueue;
  originalContextSongs: ISong[];
  originalUserSongs?: ISong[];
  currentSong: ISong | null;
  radioList: Radio[];
  isShuffleActive: boolean;
  isInUserQueue: boolean;
  playedUserQueueHistory: ISong[];
  shuffleHistory: string[];
  shuffleStartHistory: string[];
}

export type FullscreenPlayerTab =
  | "queue"
  | "playing"
  | "lyrics"
  | "customLyrics";
export type DesktopFullscreenPanelView =
  | "queue"
  | "lyrics"
  | "customLyrics"
  | null;
export type QueueTier = "context" | "user";

export interface IPlayerState {
  isPlaying: boolean;
  loopState: LoopState;
  isSongStarred: boolean;
  volume: number;
  currentDuration: number;
  mediaType: "song" | "radio";
  audioPlayerRef: HTMLAudioElement | null;
  radioPlayerRef: HTMLAudioElement | null;
  mainDrawerState: boolean;
  queueState: boolean;
  lyricsState: boolean;
  fullscreenPlayerOpen: boolean;
  fullscreenPlayerTab: FullscreenPlayerTab;
  desktopFullscreenPanelView: DesktopFullscreenPanelView;
  hasPrev: boolean;
  hasNext: boolean;
  isBuffering: boolean;
  areLyricsAligned: boolean;
  seekToStart: boolean;
  isTransitioning: boolean;
  pipWindowOpen: boolean;
}

export interface IPlayerProgress {
  progress: number;
  bufferedProgress: number;
  isScrubbing: boolean;
  scrubbingProgress: number;
}

export interface IVolumeSettings {
  min: number;
  max: number;
  step: number;
  wheelStep: number;
}

export type ReplayGainType = "track" | "album";

export type LyricsSource = "navidrome" | "lrclib" | "custom";

export interface SelectedCustomLyrics {
  key: string;
  id?: string;
  title?: string;
  artist?: string;
}

export interface SelectedCustomLyricsInput extends SelectedCustomLyrics {
  lyrics: string;
}

export const MAX_SELECTED_CUSTOM_LYRICS = 50;

interface IReplayGainData {
  enabled: boolean;
  type: ReplayGainType;
  preAmp: number;
  error: boolean;
  defaultGain: number;
}

interface IReplayGainActions {
  setReplayGainEnabled: (value: boolean) => void;
  setReplayGainType: (value: ReplayGainType) => void;
  setReplayGainPreAmp: (value: number) => void;
  setReplayGainError: (value: boolean) => void;
  setReplayGainDefaultGain: (value: number) => void;
}

interface IReplayGain {
  values: IReplayGainData;
  actions: IReplayGainActions;
}

interface IFullscreen {
  autoFullscreenEnabled: boolean;
  setAutoFullscreenEnabled: (value: boolean) => void;
}

interface ICoverArtSettings {
  useAlbumCoverForSongs: boolean;
  setUseAlbumCoverForSongs: (value: boolean) => void;
}

interface ILyrics {
  preferSyncedLyrics: boolean;
  setPreferSyncedLyrics: (value: boolean) => void;
  showTranslation: boolean;
  setShowTranslation: (value: boolean) => void;
  sourcePriority: LyricsSource[];
  setSourcePriority: (value: LyricsSource[]) => void;
  customServerEnabled: boolean;
  setCustomServerEnabled: (value: boolean) => void;
  customServerUrl: string;
  setCustomServerUrl: (value: string) => void;
  customServerPassword: string;
  setCustomServerPassword: (value: string) => void;
  selectedCustomLyrics?: Record<string, SelectedCustomLyrics>;
  setSelectedCustomLyrics: (
    songKey: string,
    lyrics: SelectedCustomLyricsInput,
  ) => Promise<void>;
}

export interface IPrivacySettings {
  lrcLibEnabled: boolean;
  setLrcLibEnabled: (value: boolean) => void;
}

interface IColorsSettings {
  currentSongColor: string | null;
  currentSongColorIntensity: number;
}

interface IHapticSettings {
  hapticFeedbackEnabled: boolean;
  setHapticFeedbackEnabled: (value: boolean) => void;
}

interface IPipSettings {
  acceptBrowserPipRequest: boolean;
  setAcceptBrowserPipRequest: (value: boolean) => void;
}

export interface IPlayerSettings {
  volume: IVolumeSettings;
  fullscreen: IFullscreen;
  coverArt: ICoverArtSettings;
  lyrics: ILyrics;
  replayGain: IReplayGain;
  privacy: IPrivacySettings;
  colors: IColorsSettings;
  hapticFeedback: IHapticSettings;
  pip: IPipSettings;
}

export interface IRemoteControlState {
  active: boolean;
  device: RemoteDeviceInfo | null;
  sendCommand: ((type: LanControlMessageType, data?: unknown) => void) | null;
}

export interface IPlayerActions {
  playSong: (song: ISong, sourceName?: string) => void;
  setSongList: (
    songlist: ISong[],
    index: number,
    shuffle?: boolean,
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ) => void;
  playFromQueue: (contextSongs: ISong[], contextIndex: number) => void;
  playFromUserQueue: (userQueueIndex: number) => void;
  setCurrentSong: () => void;
  checkIsSongStarred: () => void;
  starSongInQueue: (id: string) => void;
  starCurrentSong: () => Promise<void>;
  setPlayingState: (status: boolean) => void;
  togglePlayPause: () => void;
  toggleLoop: () => void;
  toggleShuffle: () => void;
  checkActiveSong: (id: string) => boolean;
  playNextSong: () => void;
  playPrevSong: () => void;
  hasNextSong: () => boolean;
  hasPrevSong: () => boolean;
  isPlayingOneSong: () => boolean;
  clearPlayerState: () => void;
  clearUserQueue: () => void;
  resetProgress: () => void;
  setProgress: (progress: number) => void;
  setIsScrubbing: (value: boolean) => void;
  setScrubbingProgress: (value: number) => void;
  setVolume: (volume: number) => void;
  handleVolumeWheel: (isScrollingDown: boolean) => void;
  setCurrentDuration: (duration: number) => void;
  setIsBuffering: (value: boolean) => void;
  setBufferedProgress: (value: number) => void;
  setPlayRadio: (list: Radio[], index: number) => void;
  setAudioPlayerRef: (ref: HTMLAudioElement | null) => void;
  setRadioPlayerRef: (ref: HTMLAudioElement | null) => void;
  setNextOnQueue: (
    songlist: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ) => void;
  setLastOnQueue: (
    songlist: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ) => void;
  removeSongFromQueue: (id: string, tier?: QueueTier) => void;
  reorderQueue: (fromIndex: number, toIndex: number) => void;
  setMainDrawerState: (state: boolean) => void;
  setQueueState: (state: boolean) => void;
  toggleQueueAction: () => void;
  setLyricsState: (state: boolean) => void;
  toggleLyricsAction: () => void;
  toggleQueueAndLyrics: () => void;
  closeDrawer: () => void;
  openFullscreenPlayer: (tab?: FullscreenPlayerTab) => void;
  closeFullscreenPlayer: () => void;
  setFullscreenPlayerTab: (tab: FullscreenPlayerTab) => void;
  setDesktopFullscreenPanelView: (view: DesktopFullscreenPanelView) => void;
  handleSongEnded: () => void;
  getCurrentProgress: () => number;
  resetConfig: () => void;
  updateQueueChecks: () => void;
  setAreLyricsAligned: (aligned: boolean) => void;
  setIsTransitioning: (value: boolean) => void;
  setCurrentSongColor: (value: string | null) => void;
  setCurrentSongIntensity: (value: number) => void;
  openPipWindow: () => void;
  closePipWindow: () => void;
  enterRemoteControl: (device: RemoteDeviceInfo | null) => void;
  exitRemoteControl: () => void;
  registerRemoteSender: (
    sender: (type: LanControlMessageType, data?: unknown) => void,
  ) => void;
  clearRemoteSender: () => void;
  setRemotePlayerState: (state: PlayerStateData | null) => void;
  setRemoteCurrentSongData: (song: CurrentSongData | null) => void;
  setRemoteQueueData: (queue: QueueData | null) => void;
  setRemoteDevice: (device: RemoteDeviceInfo | null) => void;
}

export interface IPlayerContext {
  songlist: ISongList;
  playerState: IPlayerState;
  playerProgress: IPlayerProgress;
  settings: IPlayerSettings;
  remoteControl: IRemoteControlState;
  actions: IPlayerActions;
}
