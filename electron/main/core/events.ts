import { is, platform } from "@electron-toolkit/utils";
import { BrowserWindow, ipcMain, nativeTheme, shell } from "electron";
import {
  IpcChannels,
  OverlayColors,
  PlayerStatePayload,
} from "../../preload/types";
import { getIsQuitting } from "../index";
import { setupMiniPlayerIpc } from "../mini-player";
import { tray, updateTray } from "../tray";
import { setupAudioSidecarIpc } from "./audioSidecarIpc";
import { colorsState } from "./colors";
import {
  clearDiscordRpcActivity,
  RpcPayload,
  setDiscordRpcActivity,
} from "./discordRpc";
import { playerState } from "./playerState";
import { getAppSetting, ISettingPayload, saveAppSettings } from "./settings";
import { setTaskbarButtons } from "./taskbar";
import { DEFAULT_TITLE_BAR_HEIGHT } from "./titleBarOverlay";

export function setupEvents(window: BrowserWindow | null) {
  if (!window) return;

  window.on("ready-to-show", async () => {
    window.show();
  });

  window.on("show", () => {
    setTaskbarButtons();
    updateTray();
  });

  window.on("hide", () => {
    updateTray();
  });

  window.webContents.once("did-finish-load", () => {
    nativeTheme.on("updated", () => {
      setTaskbarButtons();
    });
  });

  window.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url);
    return { action: "deny" };
  });

  window.on("enter-full-screen", () => {
    window.webContents.send(IpcChannels.FullscreenStatus, true);
  });

  window.on("leave-full-screen", () => {
    window.webContents.send(IpcChannels.FullscreenStatus, false);
  });

  window.on("maximize", () => {
    window.webContents.send(IpcChannels.MaximizedStatus, true);
  });

  window.on("unmaximize", () => {
    window.webContents.send(IpcChannels.MaximizedStatus, false);
  });

  window.on("close", (event) => {
    // Check if app is quitting (Cmd+Q on macOS or Quit from menu)
    if (is.dev || !getAppSetting("minimizeToTray") || getIsQuitting()) {
      if (tray && !tray.isDestroyed()) tray.destroy();
      return;
    }

    event.preventDefault();
    window.hide();
  });

  window.on("page-title-updated", (_, title) => {
    updateTray(title);
  });
}

export function setupIpcEvents(window: BrowserWindow | null) {
  if (!window) return;

  ipcMain.removeAllListeners();

  setupMiniPlayerIpc();
  setupAudioSidecarIpc(window);

  ipcMain.on(IpcChannels.ToggleFullscreen, (_, isFullscreen: boolean) => {
    window.setFullScreen(isFullscreen);
  });

  ipcMain.removeHandler(IpcChannels.IsFullScreen);
  ipcMain.handle(IpcChannels.IsFullScreen, () => {
    return window.isFullScreen();
  });

  ipcMain.removeHandler(IpcChannels.IsMaximized);
  ipcMain.handle(IpcChannels.IsMaximized, () => {
    return window.isMaximized();
  });

  ipcMain.on(IpcChannels.ToggleMaximize, (event, isMaximized: boolean) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return;
    if (isMaximized) {
      win.unmaximize();
    } else {
      win.maximize();
    }
  });

  ipcMain.on(IpcChannels.ToggleMinimize, (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return;
    win.minimize();
  });

  ipcMain.on(IpcChannels.CloseWindow, (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return;
    win.close();
  });

  ipcMain.on(IpcChannels.FocusMainWindow, () => {
    if (window && !window.isDestroyed()) {
      if (window.isMinimized()) window.restore();
      if (!window.isVisible()) window.show();
      window.focus();
    }
  });

  ipcMain.on(IpcChannels.SetAlwaysOnTop, (event, isAlwaysOnTop: boolean) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return;
    win.setAlwaysOnTop(isAlwaysOnTop);
  });

  ipcMain.removeHandler(IpcChannels.IsAlwaysOnTop);
  ipcMain.handle(IpcChannels.IsAlwaysOnTop, (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    return win?.isAlwaysOnTop() ?? false;
  });

  ipcMain.on(IpcChannels.ThemeChanged, (_, colors: OverlayColors) => {
    const { color, symbol, bgColor } = colors;

    if (bgColor) {
      colorsState.set("bgColor", bgColor);
    }

    if (platform.isMacOS || platform.isLinux) return;

    window.setTitleBarOverlay({
      color,
      height: DEFAULT_TITLE_BAR_HEIGHT,
      symbolColor: symbol,
    });
  });

  ipcMain.on(IpcChannels.UpdateNativeTheme, (_, isDark: boolean) => {
    nativeTheme.themeSource = isDark ? "dark" : "light";
  });

  ipcMain.on(
    IpcChannels.UpdatePlayerState,
    (_, payload: PlayerStatePayload) => {
      playerState.setAll(payload);

      setTimeout(() => {
        setTaskbarButtons();
        updateTray();
      }, 150);
    },
  );

  ipcMain.on(IpcChannels.SetDiscordRpcActivity, (_, payload: RpcPayload) => {
    setDiscordRpcActivity(payload);
  });

  ipcMain.on(IpcChannels.ClearDiscordRpcActivity, () => {
    clearDiscordRpcActivity();
  });

  ipcMain.on(IpcChannels.SaveAppSettings, (_, payload: ISettingPayload) => {
    saveAppSettings(payload);
  });
}
