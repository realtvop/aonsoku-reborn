import { RpcPayload } from "../main/core/discordRpc";
import { ISettingPayload } from "../main/core/settings";

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
  UpdatePlayerState = "update-player-state",
  PlayerStateListener = "player-state-listener",
  SetDiscordRpcActivity = "set-discord-rpc-activity",
  ClearDiscordRpcActivity = "clear-discord-rpc-activity",
  SaveAppSettings = "save-app-settings",
  // Mini Player
  OpenMiniPlayer = "open-mini-player",
  CloseMiniPlayer = "close-mini-player",
  IsMiniPlayerOpen = "is-mini-player-open",
  MiniPlayerStatus = "mini-player-status",
  SetAlwaysOnTop = "set-always-on-top",
  IsAlwaysOnTop = "is-always-on-top",
  FocusMainWindow = "focus-main-window",
  // Native Player Debug (desktop only)
  OpenNativeDebug = "open-native-debug",
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
  updatePlayerState: (payload: PlayerStatePayload) => void;
  playerStateListener: (
    func: (action: PlayerStateListenerActions) => void,
  ) => void;
  setDiscordRpcActivity: (payload: RpcPayload) => void;
  clearDiscordRpcActivity: () => void;
  saveAppSettings: (payload: ISettingPayload) => void;
  focusMainWindow: () => void;
  // Mini Player
  openMiniPlayer: () => void;
  closeMiniPlayer: () => void;
  isMiniPlayerOpen: () => Promise<boolean>;
  miniPlayerStatusListener: (func: (isOpen: boolean) => void) => void;
  removeMiniPlayerStatusListener: () => void;
  setAlwaysOnTop: (isAlwaysOnTop: boolean) => void;
  isAlwaysOnTop: () => Promise<boolean>;
  // Native Player Debug (desktop only)
  openNativeDebug: () => void;
  // App Update
  update: {
    checkForUpdates: () => Promise<void>;
    getVersion: () => Promise<string>;
  };
}
