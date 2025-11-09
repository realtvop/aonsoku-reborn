import { app, BrowserWindow, dialog, ipcMain } from "electron";
import { autoUpdater } from "electron-updater";
import { is } from "@electron-toolkit/utils";

export class UpdateManager {
  private mainWindow: BrowserWindow | null = null;
  private isCheckingForUpdates = false;
  private lastCheckWasManual = false;

  constructor(mainWindow: BrowserWindow) {
    this.mainWindow = mainWindow;
    this.setupAutoUpdater();
    this.setupIpcListeners();
  }

  private setupAutoUpdater() {
    // Configure auto-updater
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = true;

    // Only check for updates on production
    if (is.dev) return;

    // Check for updates when app is ready
    app.whenReady().then(() => {
      this.checkForUpdates();
    });

    // Check for updates every hour
    setInterval(
      () => {
        this.checkForUpdates();
      },
      60 * 60 * 1000,
    );

    // Handle update events
    autoUpdater.on("checking-for-update", () => {
      console.log("Checking for updates...");
      this.isCheckingForUpdates = true;
      this.sendUpdateStatus("checking-for-update");
    });

    autoUpdater.on("update-available", (info) => {
      console.log("Update available:", info);
      this.sendUpdateStatus("update-available", {
        version: info.version,
        releaseDate: info.releaseDate,
      });

      // Show notification to user
      dialog
        .showMessageBox(this.mainWindow!, {
          type: "info",
          title: "Update Available",
          message: `Version ${info.version} is available for download.`,
          buttons: ["Download Now", "Later"],
          defaultId: 0,
          cancelId: 1,
        })
        .then((result) => {
          if (result.response === 0) {
            this.downloadUpdate();
          }
        });
    });

    autoUpdater.on("update-not-available", (info) => {
      console.log("Update not available:", info);
      this.sendUpdateStatus("update-not-available");
      this.isCheckingForUpdates = false;

      // Show dialog for manual checks
      if (this.lastCheckWasManual) {
        this.lastCheckWasManual = false;
        dialog.showMessageBox(this.mainWindow!, {
          type: "info",
          title: "No Updates Available",
          message: "You're up to date!",
          detail: `Aonsoku ${app.getVersion()} is currently the newest version available.`,
          buttons: ["OK"],
        });
      }
    });

    autoUpdater.on("error", (error) => {
      console.error("Update error:", error);
      this.sendUpdateStatus("update-error", { message: error.message });
      this.isCheckingForUpdates = false;
    });

    autoUpdater.on("download-progress", (progressObj) => {
      console.log(
        `Download progress: ${progressObj.percent.toFixed(2)}% (${progressObj.transferred}/${progressObj.total})`,
      );
      this.sendUpdateStatus("update-download-progress", {
        percent: progressObj.percent,
        transferred: progressObj.transferred,
        total: progressObj.total,
      });
    });

    autoUpdater.on("update-downloaded", (info) => {
      console.log("Update downloaded, will install on quit:", info);
      this.sendUpdateStatus("update-downloaded");

      // Show notification
      dialog
        .showMessageBox(this.mainWindow!, {
          type: "info",
          title: "Update Ready",
          message: `Version ${info.version} has been downloaded and will be installed when the app is closed.`,
          buttons: ["Install Now", "Later"],
          defaultId: 0,
          cancelId: 1,
        })
        .then((result) => {
          if (result.response === 0) {
            this.quitAndInstall();
          }
        });
    });
  }

  private setupIpcListeners() {
    // Check for updates manually
    ipcMain.handle("app:check-for-updates", () => {
      return this.checkForUpdates(true);
    });

    // Download update manually
    ipcMain.handle("app:download-update", () => {
      return this.downloadUpdate();
    });

    // Install update
    ipcMain.handle("app:install-update", () => {
      this.quitAndInstall();
    });

    // Get current version
    ipcMain.handle("app:get-version", () => {
      return app.getVersion();
    });
  }

  public checkForUpdatesManually() {
    return this.checkForUpdates(true);
  }

  private checkForUpdates(isManualCheck = false) {
    if (this.isCheckingForUpdates) {
      console.log("Already checking for updates");
      if (isManualCheck) {
        dialog.showMessageBox(this.mainWindow!, {
          type: "info",
          title: "Update Check",
          message: "Already checking for updates.",
          buttons: ["OK"],
        });
      }
      return undefined;
    }

    try {
      this.isCheckingForUpdates = true;

      // Store manual check flag for use in update-not-available handler
      if (isManualCheck) {
        this.lastCheckWasManual = true;
      }

      return autoUpdater.checkForUpdates();
    } catch (error) {
      console.error("Error checking for updates:", error);
      this.isCheckingForUpdates = false;

      if (isManualCheck) {
        dialog.showMessageBox(this.mainWindow!, {
          type: "error",
          title: "Update Check Failed",
          message: "Failed to check for updates. Please try again later.",
          detail: error instanceof Error ? error.message : String(error),
          buttons: ["OK"],
        });
      }

      return undefined;
    }
  }

  private downloadUpdate() {
    console.log("Starting download...");
    autoUpdater.downloadUpdate();
  }

  private quitAndInstall() {
    autoUpdater.quitAndInstall();
  }

  private sendUpdateStatus(status: string, data?: Record<string, unknown>) {
    if (this.mainWindow && !this.mainWindow.isDestroyed()) {
      this.mainWindow.webContents.send("app:update-status", {
        status,
        ...data,
      });
    }
  }
}
