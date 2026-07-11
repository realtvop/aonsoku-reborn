import { electronAPI } from "@electron-toolkit/preload";
import { contextBridge, ipcRenderer } from "electron";
import { aonsokuNativeAudioBridge } from "./native-audio";
import { aonsokuNativeBridge } from "./native-bridge";
import { aonsokuNativeCoordination } from "./native-coordination";
import { aonsokuNativeData } from "./native-data";
import { aonsokuNativePreferences } from "./native-preferences";
import { IAonsokuAPI, IpcChannels, PlayerStateListenerActions } from "./types";

// Custom APIs for renderer
const api: IAonsokuAPI = {
  enterFullScreen: () => ipcRenderer.send(IpcChannels.ToggleFullscreen, true),
  exitFullScreen: () => ipcRenderer.send(IpcChannels.ToggleFullscreen, false),
  isFullScreen: () => ipcRenderer.invoke(IpcChannels.IsFullScreen),
  fullscreenStatusListener: (func) => {
    ipcRenderer.on(IpcChannels.FullscreenStatus, (_, status: boolean) =>
      func(status),
    );
  },
  removeFullscreenStatusListener: () => {
    ipcRenderer.removeAllListeners(IpcChannels.FullscreenStatus);
  },
  isMaximized: () => ipcRenderer.invoke(IpcChannels.IsMaximized),
  maximizedStatusListener: (func) => {
    ipcRenderer.on(IpcChannels.MaximizedStatus, (_, status: boolean) =>
      func(status),
    );
  },
  removeMaximizedStatusListener: () => {
    ipcRenderer.removeAllListeners(IpcChannels.MaximizedStatus);
  },
  toggleMaximize: (isMaximized) =>
    ipcRenderer.send(IpcChannels.ToggleMaximize, isMaximized),
  toggleMinimize: () => ipcRenderer.send(IpcChannels.ToggleMinimize),
  closeWindow: () => ipcRenderer.send(IpcChannels.CloseWindow),
  focusMainWindow: () => ipcRenderer.send(IpcChannels.FocusMainWindow),
  setTitleBarOverlayColors: (color) =>
    ipcRenderer.send(IpcChannels.ThemeChanged, color),
  setNativeTheme: (isDark) =>
    ipcRenderer.send(IpcChannels.UpdateNativeTheme, isDark),
  updatePlayerState: (payload) => {
    ipcRenderer.send(IpcChannels.UpdatePlayerState, payload);
  },
  playerStateListener: (func) => {
    ipcRenderer.on(
      IpcChannels.PlayerStateListener,
      (_, state: PlayerStateListenerActions) => func(state),
    );
  },
  setDiscordRpcActivity: (payload) => {
    ipcRenderer.send(IpcChannels.SetDiscordRpcActivity, payload);
  },
  clearDiscordRpcActivity: () => {
    ipcRenderer.send(IpcChannels.ClearDiscordRpcActivity);
  },
  saveAppSettings: (payload) => {
    ipcRenderer.send(IpcChannels.SaveAppSettings, payload);
  },
  // Mini Player
  openMiniPlayer: () => ipcRenderer.send(IpcChannels.OpenMiniPlayer),
  closeMiniPlayer: () => ipcRenderer.send(IpcChannels.CloseMiniPlayer),
  isMiniPlayerOpen: () => ipcRenderer.invoke(IpcChannels.IsMiniPlayerOpen),
  miniPlayerStatusListener: (func) => {
    ipcRenderer.on(IpcChannels.MiniPlayerStatus, (_, isOpen: boolean) =>
      func(isOpen),
    );
  },
  removeMiniPlayerStatusListener: () => {
    ipcRenderer.removeAllListeners(IpcChannels.MiniPlayerStatus);
  },
  setAlwaysOnTop: (isAlwaysOnTop) =>
    ipcRenderer.send(IpcChannels.SetAlwaysOnTop, isAlwaysOnTop),
  isAlwaysOnTop: () => ipcRenderer.invoke(IpcChannels.IsAlwaysOnTop),
  // Native Player Debug (desktop only)
  openNativeDebug: () => ipcRenderer.send(IpcChannels.OpenNativeDebug),
  // App Update
  update: {
    checkForUpdates: () => ipcRenderer.invoke("app:check-for-updates"),
    getVersion: () => ipcRenderer.invoke("app:get-version"),
  },
};

// Use `contextBridge` APIs to expose Electron APIs to
// renderer only if context isolation is enabled, otherwise
// just add to the DOM global.
if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld("electron", electronAPI);
    contextBridge.exposeInMainWorld("api", api);
    contextBridge.exposeInMainWorld(
      "aonsokuNativeAudio",
      aonsokuNativeAudioBridge,
    );
    contextBridge.exposeInMainWorld("aonsokuNativeBridge", aonsokuNativeBridge);
    contextBridge.exposeInMainWorld("aonsokuNativeData", aonsokuNativeData);
    contextBridge.exposeInMainWorld(
      "aonsokuNativePreferences",
      aonsokuNativePreferences,
    );
    contextBridge.exposeInMainWorld(
      "aonsokuNativeCoordination",
      aonsokuNativeCoordination,
    );
  } catch (error) {
    console.error(error);
  }
} else {
  // @ts-expect-error (define in dts)
  window.electron = electronAPI;
  // @ts-expect-error (define in dts)
  window.api = api;
  // @ts-expect-error (define in dts)
  window.aonsokuNativeAudio = aonsokuNativeAudioBridge;
  // @ts-expect-error (define in dts)
  window.aonsokuNativeBridge = aonsokuNativeBridge;
  // @ts-expect-error (define in dts)
  window.aonsokuNativeData = aonsokuNativeData;
  // @ts-expect-error (define in dts)
  window.aonsokuNativePreferences = aonsokuNativePreferences;
  // @ts-expect-error (define in dts)
  window.aonsokuNativeCoordination = aonsokuNativeCoordination;
}
