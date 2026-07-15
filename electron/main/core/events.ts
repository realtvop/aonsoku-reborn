import { is, platform } from "@electron-toolkit/utils";
import { BrowserWindow, ipcMain, nativeTheme, shell } from "electron";
import {
  IpcChannels,
  OverlayColors,
  PlayerStatePayload,
} from "../../preload/types";
import { getIsQuitting } from "../index";
import { setupMiniPlayerIpc } from "../mini-player";
import { setupDesktopNativeAudioIpc } from "../native/audio/ipc";
import {
  desktopNativeBridgeService,
  setupDesktopNativeBridgeIpc,
} from "../native/bridge/ipc";
import { setupDesktopNativeCoordinationIpc } from "../native/coordination/ipc";
import { setupDesktopNativeDataIpc } from "../native/data/ipc";
import { setupDesktopNativeDebugIpc } from "../native/debug/ipc";
import { setupNativeDebugWindowIpc } from "../native/debug/native-debug-window";
import { setupDesktopNativePreferencesIpc } from "../native/preferences/ipc";
import { tray, updateTray } from "../tray";
import { colorsState } from "./colors";
import {
  clearDiscordRpcActivity,
  RpcPayload,
  setDiscordRpcActivity,
} from "./discordRpc";
import { setupDesktopPlaybackControlChrome } from "./playerControls";
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
  setupNativeDebugWindowIpc();
  const resolveDesktopMediaUrl = (url: string): string => {
    if (!url.startsWith("aonsoku-media://")) return url;
    const parsed = new URL(url);
    if ((parsed.hostname || parsed.pathname.replace(/^\//, "")) !== "stream") {
      throw new Error(`Unsupported desktop media source: ${url}`);
    }
    return desktopNativeBridgeService
      .getMediaUrl("/stream.view", Object.fromEntries(parsed.searchParams))
      .toString();
  };
  // The native system media session (libmpv addon on macOS, MPRIS on Linux)
  // downloads cover art with platform HTTP clients that cannot resolve the
  // renderer's `aonsoku-media://` custom protocol. Translate cover-art
  // references (either `aonsoku-media://getCoverArt?id=...` URLs from renderer
  // loads or bare cover-art ids from queue-driven loads) into authenticated
  // Subsonic HTTP URLs the platform clients can fetch.
  const resolveDesktopArtworkUrl = (
    artworkUrl: string | undefined,
  ): string | undefined => {
    if (!artworkUrl) return undefined;
    try {
      if (artworkUrl.startsWith("aonsoku-media://")) {
        const parsed = new URL(artworkUrl);
        const operation = parsed.hostname || parsed.pathname.replace(/^\//, "");
        if (operation !== "getCoverArt") return undefined;
        return desktopNativeBridgeService
          .getMediaUrl(
            "/getCoverArt.view",
            Object.fromEntries(parsed.searchParams),
          )
          .toString();
      }
      // Queue-driven loads store the raw cover-art id without a scheme.
      if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(artworkUrl)) {
        return desktopNativeBridgeService
          .getMediaUrl("/getCoverArt.view", {
            id: artworkUrl,
            size: "300",
          })
          .toString();
      }
      return artworkUrl;
    } catch {
      // No credentials / unsupported reference: leave artwork unset rather than
      // surfacing a broken URL to the platform media session.
      return undefined;
    }
  };
  setupDesktopNativeAudioIpc(window, {
    streamUrlResolver: resolveDesktopMediaUrl,
    downloadUrlResolver: ({ songId, maxBitRate, format }) =>
      desktopNativeBridgeService
        .getMediaUrl("/stream.view", {
          id: songId,
          ...(maxBitRate ? { maxBitRate } : {}),
          ...(format ? { format } : {}),
        })
        .toString(),
    artworkUrlResolver: resolveDesktopArtworkUrl,
    scrobbleRequest: (options) => desktopNativeBridgeService.request(options),
  });
  setupDesktopNativeBridgeIpc();
  setupDesktopNativeDataIpc(window);
  setupDesktopNativePreferencesIpc();
  setupDesktopNativeCoordinationIpc(window);
  setupDesktopNativeDebugIpc();
  setupDesktopPlaybackControlChrome(() => {
    setTaskbarButtons();
    updateTray();
  });

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
