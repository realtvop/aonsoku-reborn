import type { BrowserWindow } from "electron";
import type { IncomingMessage } from "node:http";
import { createServer, type Server as HttpServer } from "node:http";
import path from "node:path";
import type { Express, Request, Response } from "express";
import { WebSocket, WebSocketServer } from "ws";
import {
  LanControlConfig,
  LanControlMessage,
  LanControlMessageType,
  AuthRequestData,
  AuthResponseData,
  PlayerStateData,
  CurrentSongData,
  QueueData,
} from "./lanControlTypes";
import { i18n } from "./i18n";

// These will be dynamically imported when server starts
// type Express = any
// type Request = any
// type Response = any
// type WebSocketServer = any
// type WebSocket = any

// const __dirname = path.dirname(fileURLToPath(import.meta.url))

export class LanControlServer {
  private app: Express | null = null;
  private httpServer: HttpServer | null = null;
  private wss: WebSocketServer | null = null;
  private port: number;
  private config: LanControlConfig;
  private mainWindow: BrowserWindow | null = null;
  private clients: Set<WebSocket> = new Set();

  constructor(config: LanControlConfig, mainWindow: BrowserWindow) {
    this.config = config;
    this.port = config.port;
    this.mainWindow = mainWindow;
  }

  async start(): Promise<{ success: boolean; port?: number; error?: string }> {
    try {
      if (this.httpServer) {
        return { success: false, error: i18n.en.server.alreadyRunning };
      }

      // Dynamically import dependencies
      const express = (await import("express")).default;
      const cors = (await import("cors")).default;
      const { WebSocketServer } = await import("ws");

      this.app = express();
      this.app.use(cors());
      this.app.use(express.json());

      const publicDir = path.join(__dirname, "../../../public");

      // Serve static control page
      this.app.use(express.static(publicDir));

      // Serve control page on root path
      this.app.get("/", (_req: Request, res: Response) => {
        res.sendFile(path.join(publicDir, "control.html"));
      });

      // Health check endpoint
      this.app.get("/api/health", (_req: Request, res: Response) => {
        res.json({ status: i18n.en.server.healthStatus, version: "1.0.0" });
      });

      // Serve control page
      this.app.get("/control", (_req: Request, res: Response) => {
        res.sendFile(path.join(publicDir, "control.html"));
      });

      // Create HTTP server
      this.httpServer = createServer(this.app);

      // Create WebSocket server
      this.wss = new WebSocketServer({ server: this.httpServer });

      this.wss.on("connection", (ws: WebSocket, req: IncomingMessage) => {
        console.log(
          "[LAN Control] New client connected from",
          req.socket.remoteAddress,
        );

        let isAuthenticated = false;
        let authTimeout: NodeJS.Timeout | null = null;

        // Set authentication timeout (30 seconds)
        authTimeout = setTimeout(() => {
          if (!isAuthenticated) {
            ws.send(
              JSON.stringify({
                type: LanControlMessageType.ERROR,
                data: { message: i18n.en.auth.timeout },
              } as LanControlMessage),
            );
            ws.close();
          }
        }, 30000);

        ws.on("message", async (message: Buffer) => {
          try {
            const msg: LanControlMessage = JSON.parse(message.toString());

            // Handle authentication
            if (msg.type === LanControlMessageType.AUTH_REQUEST) {
              if (authTimeout) {
                clearTimeout(authTimeout);
                authTimeout = null;
              }

              const authData = msg.data as AuthRequestData;
              const authResult = await this.authenticate(authData);

              const response: LanControlMessage = {
                type: LanControlMessageType.AUTH_RESPONSE,
                data: {
                  success: authResult,
                  message: authResult
                    ? i18n.en.auth.success
                    : i18n.en.auth.failed,
                  deviceInfo: authResult
                    ? {
                      name: "Aonsoku Desktop",
                      version: "0.20.0",
                    }
                    : undefined,
                } as AuthResponseData,
              };

              ws.send(JSON.stringify(response));

              if (authResult) {
                isAuthenticated = true;
                this.clients.add(ws);
                console.log("[LAN Control] Client authenticated");
                // Send initial state
                this.sendCurrentState(ws);
              } else {
                ws.close();
              }
              return;
            }

            // Check authentication for other messages
            if (!isAuthenticated) {
              ws.send(
                JSON.stringify({
                  type: LanControlMessageType.ERROR,
                  data: { message: i18n.en.auth.notAuthenticated },
                } as LanControlMessage),
              );
              return;
            }

            // Handle control messages
            this.handleControlMessage(msg, ws);
          } catch (error) {
            console.error("[LAN Control] Error processing message:", error);
            ws.send(
              JSON.stringify({
                type: LanControlMessageType.ERROR,
                data: { message: i18n.en.error.invalidMessage },
              } as LanControlMessage),
            );
          }
        });

        ws.on("close", () => {
          if (authTimeout) {
            clearTimeout(authTimeout);
          }
          this.clients.delete(ws);
          console.log("[LAN Control] Client disconnected");
        });

        ws.on("error", (error) => {
          console.error("[LAN Control] WebSocket error:", error);
          this.clients.delete(ws);
        });
      });

      // Start server
      await new Promise<void>((resolve, reject) => {
        this.httpServer!.listen(this.port, () => {
          console.log(`[LAN Control] Server started on port ${this.port}`);
          resolve();
        }).on("error", (err: NodeJS.ErrnoException) => {
          if (err.code === "EADDRINUSE") {
            reject(new Error(`Port ${this.port} is already in use`));
          } else {
            reject(err);
          }
        });
      });

      return { success: true, port: this.port };
    } catch (error) {
      console.error("[LAN Control] Failed to start server:", error);
      return {
        success: false,
        error: error instanceof Error ? error.message : "Unknown error",
      };
    }
  }

  async stop(): Promise<void> {
    return new Promise((resolve) => {
      // Close all WebSocket connections
      for (const client of this.clients) {
        client.close();
      }
      this.clients.clear();

      // Close WebSocket server
      if (this.wss) {
        this.wss.close(() => {
          console.log("[LAN Control] WebSocket server closed");
        });
        this.wss = null;
      }

      // Close HTTP server
      if (this.httpServer) {
        this.httpServer.close(() => {
          console.log("[LAN Control] HTTP server closed");
          this.httpServer = null;
          resolve();
        });
      } else {
        resolve();
      }
    });
  }

  private async authenticate(authData: AuthRequestData): Promise<boolean> {
    if (authData.authType === "lan") {
      // Check LAN password (case insensitive)
      return (
        authData.password.toUpperCase() === this.config.password.toUpperCase()
      );
    } else if (
      authData.authType === "navidrome" &&
      this.config.allowNavidromeAuth
    ) {
      // Check Navidrome credentials
      if (!authData.username) {
        return false;
      }
      // Send auth request to main window
      return new Promise((resolve) => {
        this.mainWindow?.webContents.send("lan-control:verify-navidrome-auth", {
          username: authData.username,
          password: authData.password,
          callback: (result: boolean) => resolve(result),
        });
      });
    }
    return false;
  }

  private handleControlMessage(msg: LanControlMessage, ws: WebSocket): void {
    if (!this.mainWindow) {
      ws.send(
        JSON.stringify({
          type: LanControlMessageType.ERROR,
          data: { message: i18n.en.error.mainWindowUnavailable },
        } as LanControlMessage),
      );
      return;
    }

    // Forward control message to renderer
    this.mainWindow.webContents.send("lan-control:message", msg);

    // Handle state requests immediately
    switch (msg.type) {
      case LanControlMessageType.GET_STATE:
      case LanControlMessageType.GET_CURRENT_SONG:
      case LanControlMessageType.GET_QUEUE:
        // These will be responded by the renderer via IPC
        break;
    }
  }

  private sendCurrentState(_ws: WebSocket): void {
    if (!this.mainWindow) return;

    // Request current state from renderer
    this.mainWindow.webContents.send("lan-control:request-state");
  }

  // Public method to broadcast state updates to all clients
  broadcastStateUpdate(state: PlayerStateData): void {
    const message: LanControlMessage = {
      type: LanControlMessageType.STATE_UPDATE,
      data: state,
      timestamp: Date.now(),
    };
    this.broadcast(message);
  }

  broadcastCurrentSong(song: CurrentSongData): void {
    const message: LanControlMessage = {
      type: LanControlMessageType.CURRENT_SONG_UPDATE,
      data: song,
      timestamp: Date.now(),
    };
    this.broadcast(message);
  }

  broadcastQueue(queue: QueueData): void {
    const message: LanControlMessage = {
      type: LanControlMessageType.QUEUE_UPDATE,
      data: queue,
      timestamp: Date.now(),
    };
    this.broadcast(message);
  }

  private broadcast(message: LanControlMessage): void {
    const json = JSON.stringify(message);
    for (const client of this.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(json);
      }
    }
  }

  updateConfig(config: LanControlConfig): void {
    this.config = config;
    this.port = config.port;
  }

  isRunning(): boolean {
    return this.httpServer !== null;
  }

  getPort(): number {
    return this.port;
  }
}
