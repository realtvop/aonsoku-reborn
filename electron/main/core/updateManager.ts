import { app, BrowserWindow, dialog, ipcMain } from "electron";
import { is } from "@electron-toolkit/utils";
import updateElectronApp from "update-electron-app";

export class UpdateManager {
  private mainWindow: BrowserWindow | null = null;
  private isCheckingForUpdates = false;

  constructor(mainWindow: BrowserWindow) {
    this.mainWindow = mainWindow;
    this.setupUpdateElectronApp();
    this.setupIpcListeners();
  }

  private setupUpdateElectronApp() {
    // Only initialize updates in production
    if (is.dev) return;

    try {
      updateElectronApp({
        repo: "realtvop/aonsoku-reborn",
        owner: "realtvop",
        // Auto-check for updates every hour (3600000ms)
        checkInterval: 60 * 60 * 1000,
        // Automatically download updates in the background
        autoDownload: true,
        // Don't auto-install on quit
        autoInstallOnAppQuit: false,
        // Use custom dialog for update notifications
        notifyUser: true,
        // Make logger optional to reduce noise
        logger: undefined,
      });
    } catch (error) {
      console.error("Failed to initialize update-electron-app:", error);
    }
  }

  private setupIpcListeners() {
    // Handle manual check for updates
    ipcMain.handle("app:check-for-updates", async () => {
      return this.checkForUpdatesManually();
    });

    // Get current version
    ipcMain.handle("app:get-version", () => {
      return app.getVersion();
    });
  }

  public async checkForUpdatesManually() {
    if (this.isCheckingForUpdates) {
      console.log("Already checking for updates");
      dialog.showMessageBox(this.mainWindow!, {
        type: "info",
        title: "Update Check",
        message: "Already checking for updates.",
        buttons: ["OK"],
      });
      return undefined;
    }

    try {
      this.isCheckingForUpdates = true;
      console.log("Manually checking for updates...");

      // Note: update-electron-app handles updates automatically
      // This dialog is informational only
      dialog.showMessageBox(this.mainWindow!, {
        type: "info",
        title: "Update Check",
        message: "Checking for updates...",
        buttons: ["OK"],
      });

      return undefined;
    } catch (error) {
      console.error("Error checking for updates:", error);
      this.isCheckingForUpdates = false;

      dialog.showMessageBox(this.mainWindow!, {
        type: "error",
        title: "Update Check Failed",
        message: "Failed to check for updates. Please try again later.",
        detail: error instanceof Error ? error.message : String(error),
        buttons: ["OK"],
      });

      return undefined;
    } finally {
      this.isCheckingForUpdates = false;
    }
  }
}
