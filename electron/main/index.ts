import { electronApp, optimizer, platform } from "@electron-toolkit/utils";
import { app, globalShortcut } from "electron";
import { updateElectronApp } from "update-electron-app";

import { createAppMenu } from "./core/menu";
import { destroyMiniPlayerWindow } from "./mini-player";
import { destroyDesktopNativeAudioService } from "./native/audio/ipc";
import {
  registerDesktopMediaScheme,
  setupDesktopMediaProtocol,
} from "./native/media-protocol";
import { createWindow, mainWindow } from "./window";

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
    const nativeAudioDestroyed = destroyDesktopNativeAudioService();
    if (nativeAudioDestroyed) {
      nativeAudioDestroyed.catch((error) => {
        console.error("Failed to destroy desktop native audio service.", error);
      });
    }
  });
}

updateElectronApp();
