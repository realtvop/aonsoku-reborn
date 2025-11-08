import { electronApp, optimizer } from "@electron-toolkit/utils";
import { app, globalShortcut } from "electron";
import { createAppMenu } from "./core/menu";
import { createWindow, mainWindow } from "./window";
import { LanControlManager } from "./core/lanControlManager";
import { UpdateManager } from "./core/updateManager";

let lanControlManager: LanControlManager | null = null;
let updateManager: UpdateManager | null = null;

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
    electronApp.setAppUserModelId("com.victoralvesf.aonsoku");

    createWindow();

    // Initialize LAN Control Manager after window is created
    if (mainWindow) {
      lanControlManager = new LanControlManager(mainWindow);
      updateManager = new UpdateManager(mainWindow);
    }
  });

  app.on("activate", function () {
    if (!mainWindow || mainWindow.isDestroyed()) {
      createWindow();

      // Re-initialize LAN Control Manager if needed
      if (mainWindow && !lanControlManager) {
        lanControlManager = new LanControlManager(mainWindow);
      }

      // Re-initialize Update Manager if needed
      if (mainWindow && !updateManager) {
        updateManager = new UpdateManager(mainWindow);
      }
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
    globalShortcut.register("F11", () => { });
  });

  app.on("window-all-closed", () => {
    // Cleanup LAN Control Manager
    if (lanControlManager) {
      lanControlManager.cleanup();
      lanControlManager = null;
    }
    app.quit();
  });

  app.on("before-quit", () => {
    // Ensure LAN Control server is stopped before quitting
    if (lanControlManager) {
      lanControlManager.cleanup();
    }
  });
}
