/**
 * LAN Control Server Manager
 * Manages the lifecycle of the LAN control server
 */

import { BrowserWindow, ipcMain } from "electron";
import type {
  LanControlConfig,
  LanControlServerInfo,
  PlayerStateData,
  CurrentSongData,
  QueueData,
  LanControlMessage,
} from "./lanControlTypes";
import type { LanControlServer as LanControlServerType } from "./lanControlServer";

// Import will be done dynamically when server starts
let LanControlServer: typeof LanControlServerType | null = null;

export class LanControlManager {
  private server: LanControlServerType | null = null;
  private mainWindow: BrowserWindow | null = null;
  private config: LanControlConfig | null = null;

  constructor(mainWindow: BrowserWindow) {
    this.mainWindow = mainWindow;
    this.setupIpcHandlers();
  }

  private setupIpcHandlers(): void {
    // Start server
    ipcMain.handle(
      "lan-control:start",
      async (_event, config: LanControlConfig) => {
        return await this.start(config);
      },
    );

    // Stop server
    ipcMain.handle("lan-control:stop", async () => {
      return await this.stop();
    });

    // Get server info
    ipcMain.handle("lan-control:get-info", async () => {
      return this.getInfo();
    });

    // Update config
    ipcMain.handle(
      "lan-control:update-config",
      async (_event, config: LanControlConfig) => {
        return await this.updateConfig(config);
      },
    );

    // Broadcast state
    ipcMain.on(
      "lan-control:broadcast-state",
      (_event, state: PlayerStateData) => {
        this.broadcastState(state);
      },
    );

    // Broadcast song
    ipcMain.on(
      "lan-control:broadcast-song",
      (_event, song: CurrentSongData) => {
        this.broadcastSong(song);
      },
    );

    // Broadcast queue
    ipcMain.on("lan-control:broadcast-queue", (_event, queue: QueueData) => {
      this.broadcastQueue(queue);
    });
  }

  async start(config: LanControlConfig): Promise<LanControlServerInfo> {
    try {
      this.config = config;

      // Dynamically import the server class
      if (!LanControlServer) {
        const module = await import("./lanControlServer.js");
        LanControlServer = module.LanControlServer;
      }

      if (this.server) {
        await this.stop();
      }

      if (!this.mainWindow) {
        return {
          running: false,
          port: config.port,
          error: "Main window not available",
        };
      }

      this.server = new LanControlServer(config, this.mainWindow);
      const result = await this.server.start();

      return {
        running: result.success,
        port: result.port || config.port,
        address: result.success ? `http://localhost:${result.port}` : undefined,
        error: result.error,
      };
    } catch (error) {
      console.error("[LAN Control Manager] Failed to start server:", error);
      return {
        running: false,
        port: config.port,
        error: error instanceof Error ? error.message : "Unknown error",
      };
    }
  }

  async stop(): Promise<void> {
    if (this.server) {
      await this.server.stop();
      this.server = null;
    }
  }

  getInfo(): LanControlServerInfo {
    if (!this.server || !this.config) {
      return {
        running: false,
        port: 5299,
      };
    }

    return {
      running: this.server.isRunning(),
      port: this.server.getPort(),
      address: this.server.isRunning()
        ? `http://localhost:${this.server.getPort()}`
        : undefined,
    };
  }

  async updateConfig(config: LanControlConfig): Promise<void> {
    this.config = config;

    if (this.server) {
      this.server.updateConfig(config);

      // If port changed and server is running, restart
      if (config.enabled && this.server.getPort() !== config.port) {
        await this.stop();
        await this.start(config);
      }
    }
  }

  broadcastState(state: PlayerStateData): void {
    if (this.server && this.server.isRunning()) {
      this.server.broadcastStateUpdate(state);
    }
  }

  broadcastSong(song: CurrentSongData): void {
    if (this.server && this.server.isRunning()) {
      this.server.broadcastCurrentSong(song);
    }
  }

  broadcastQueue(queue: QueueData): void {
    if (this.server && this.server.isRunning()) {
      this.server.broadcastQueue(queue);
    }
  }

  // Handle messages from renderer to forward to clients
  handleMessage(_message: LanControlMessage): void {
    // This would be used to send responses back to connected clients
    // For now, the server handles this internally
  }

  cleanup(): void {
    if (this.server) {
      this.stop();
    }
  }
}
