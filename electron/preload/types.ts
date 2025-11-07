import { RpcPayload } from "../main/core/discordRpc";
import { IDownloadPayload } from "../main/core/downloads";
import { ISettingPayload } from "../main/core/settings";
import type {
  LanControlConfig,
  LanControlServerInfo,
  LanControlMessage,
  PlayerStateData,
  CurrentSongData,
  QueueData,
} from "./lanControlTypes";

export enum IpcChannels {
  FullscreenStatus = "fullscreen-status",
  ToggleFullscreen = "toggle-fullscreen",
  IsFullScreen = "is-fullscreen",
  IsMaximized = "is-maximized",
  MaximizedStatus = "maximized-status",
  ToggleMaximize = "toggle-maximize",
  ToggleMinimize = "toggle-minimize",
  CloseWindow = "close-window",
  ThemeChanged = "theme-changed",
  UpdateNativeTheme = "update-native-theme",
  HandleDownloads = "handle-downloads",
  DownloadCompleted = "download-completed",
  DownloadFailed = "download-failed",
  UpdatePlayerState = "update-player-state",
  PlayerStateListener = "player-state-listener",
  SetDiscordRpcActivity = "set-discord-rpc-activity",
  ClearDiscordRpcActivity = "clear-discord-rpc-activity",
  SaveAppSettings = "save-app-settings",
  // LAN Control
  LanControlStart = "lan-control:start",
  LanControlStop = "lan-control:stop",
  LanControlGetInfo = "lan-control:get-info",
  LanControlUpdateConfig = "lan-control:update-config",
  LanControlBroadcastState = "lan-control:broadcast-state",
  LanControlBroadcastSong = "lan-control:broadcast-song",
  LanControlBroadcastQueue = "lan-control:broadcast-queue",
  LanControlMessage = "lan-control:message",
  LanControlRequestState = "lan-control:request-state",
  LanControlVerifyNavidromeAuth = "lan-control:verify-navidrome-auth",
}

export type OverlayColors = {
  color: string;
  symbol: string;
  bgColor: string;
};

export type PlayerStatePayload = {
  isPlaying: boolean;
  hasPrevious: boolean;
  hasNext: boolean;
  hasSonglist: boolean;
};

export type PlayerStateListenerActions =
  | "togglePlayPause"
  | "skipBackwards"
  | "skipForward"
  | "toggleShuffle"
  | "toggleRepeat";

export interface IAonsokuAPI {
  enterFullScreen: () => void;
  exitFullScreen: () => void;
  isFullScreen: () => Promise<boolean>;
  fullscreenStatusListener: (func: (status: boolean) => void) => void;
  removeFullscreenStatusListener: () => void;
  isMaximized: () => Promise<boolean>;
  maximizedStatusListener: (func: (status: boolean) => void) => void;
  removeMaximizedStatusListener: () => void;
  toggleMaximize: (isMaximized: boolean) => void;
  toggleMinimize: () => void;
  closeWindow: () => void;
  setTitleBarOverlayColors: (colors: OverlayColors) => void;
  setNativeTheme: (isDark: boolean) => void;
  downloadFile: (payload: IDownloadPayload) => void;
  downloadCompletedListener: (func: (fileId: string) => void) => void;
  downloadFailedListener: (func: (fileId: string) => void) => void;
  updatePlayerState: (payload: PlayerStatePayload) => void;
  playerStateListener: (
    func: (action: PlayerStateListenerActions) => void,
  ) => void;
  setDiscordRpcActivity: (payload: RpcPayload) => void;
  clearDiscordRpcActivity: () => void;
  saveAppSettings: (payload: ISettingPayload) => void;
  // LAN Control
  lanControl: {
    start: (config: LanControlConfig) => Promise<LanControlServerInfo>;
    stop: () => Promise<void>;
    getInfo: () => Promise<LanControlServerInfo>;
    updateConfig: (config: LanControlConfig) => Promise<void>;
    broadcastState: (state: PlayerStateData) => void;
    broadcastSong: (song: CurrentSongData) => void;
    broadcastQueue: (queue: QueueData) => void;
    onMessage: (callback: (message: LanControlMessage) => void) => void;
    onRequestState: (callback: () => void) => void;
    removeMessageListener: () => void;
    removeRequestStateListener: () => void;
  };
}
