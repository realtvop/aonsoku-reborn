import { electronApp, optimizer, platform } from "@electron-toolkit/utils";
import { app, globalShortcut } from "electron";
import { updateElectronApp } from "update-electron-app";

import { createAppMenu } from "./core/menu";
import { destroyMiniPlayerWindow } from "./mini-player";
import { destroyDesktopNativeAudioService } from "./native/audio/ipc";
import { destroyNativeDebugWindow } from "./native/debug/native-debug-window";
import {
  registerDesktopMediaScheme,
  setupDesktopMediaProtocol,
} from "./native/media-protocol";
import { createWindow, mainWindow } from "./window";

// The libmpv native addon owns the macOS system media session
// (MPNowPlayingInfoCenter + MPRemoteCommandCenter) and the renderer disables
// navigator.mediaSession so the addon is the single source of truth.
// Chromium's HardwareMediaKeyHandling feature (on by default for audio-playing
// Electron apps) also claims the Now Playing slot and routes Control Center /
// media-key commands to its own RemoteCommandCenterDelegate, which starves the
// addon's command handlers — play/pause, the scrubber, and media keys stop
// firing. Disable it on macOS so the addon is the sole media session owner and
// its MPRemoteCommandCenter handlers receive the system commands. This must
// run before app.whenReady() so the feature is disabled before Chromium
// initializes. Windows/Linux keep Chromium's handling because the addon's
// system command reception there is still display-only.
if (process.platform === "darwin") {
  app.commandLine.appendSwitch("disable-features", "HardwareMediaKeyHandling");
}

registerDesktopMediaScheme();

let isQuitting = false;

export function getIsQuitting(): boolean {
  return isQuitting;
}

const instanceLock = app.requestSingleInstanceLock();

if (!instanceLock) {
  app.quit();
} else {
  createAppMenu();

  app.on("second-instance", () => {
    if (!mainWindow || mainWindow.isDestroyed()) return;

    if (mainWindow.isMinimized()) mainWindow.restore();

    mainWindow.focus();
  });

  app.whenReady().then(() => {
    electronApp.setAppUserModelId("com.realtvop.aonsoku");

    setupDesktopMediaProtocol();

    createWindow();
  });

  app.on("activate", function () {
    if (!mainWindow || mainWindow.isDestroyed()) {
      createWindow();

      return;
    }

    if (mainWindow.isMinimized()) {
      mainWindow.restore();
    } else if (!mainWindow.isVisible()) {
      mainWindow.show();
    }

    mainWindow.focus();
  });

  app.on("browser-window-created", (_, window) => {
    optimizer.watchWindowShortcuts(window);
    globalShortcut.register("F11", () => {});
  });

  app.on("window-all-closed", () => {
    // On macOS, keep the app running even when all windows are closed
    // This is the standard macOS behavior
    if (platform.isMacOS && !isQuitting) {
      return;
    }

    app.quit();
  });

  app.on("before-quit", () => {
    isQuitting = true;

    destroyMiniPlayerWindow();
    destroyNativeDebugWindow();
    const nativeAudioDestroyed = destroyDesktopNativeAudioService();
    if (nativeAudioDestroyed) {
      nativeAudioDestroyed.catch((error) => {
        console.error("Failed to destroy desktop native audio service.", error);
      });
    }
  });
}

updateElectronApp();
