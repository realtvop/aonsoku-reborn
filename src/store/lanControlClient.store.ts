import { createWithEqualityFn } from "zustand/traditional";
import { shallow } from "zustand/shallow";
import {
  AuthResponseData,
  CurrentSongData,
  LanControlMessage,
  LanControlMessageType,
  PlayerStateData,
  QueueData,
  RemoteDeviceInfo,
} from "@/types/lanControl";
import { usePlayerStore } from "./player.store";

type ConnectionStatus =
  | "disconnected"
  | "connecting"
  | "authenticating"
  | "connected"
  | "error";

type SendPayload = {
  type: LanControlMessageType;
  data?: unknown;
};
interface LanControlClientState {
  status: ConnectionStatus;
  ip: string;
  port: number;
  password: string;
  error?: string;
  remoteDevice: RemoteDeviceInfo | null;
  playerState: PlayerStateData | null;
  currentSong: CurrentSongData | null;
  queue: QueueData | null;
  lastMessageAt: number | null;
  actions: {
    setIp: (ip: string) => void;
    setPort: (port: number) => void;
    setPassword: (password: string) => void;
    connect: () => void;
    disconnect: () => void;
    clearError: () => void;
    send: (payload: SendPayload) => void;
  };
}

let socket: WebSocket | null = null;
let reconnectAbort = false;

function parseMessage(event: MessageEvent<string>): LanControlMessage | null {
  try {
    return JSON.parse(event.data) as LanControlMessage;
  } catch (error) {
    console.error("[LAN Control Client] Failed to parse message", error);
    return null;
  }
}

function closeSocket() {
  if (socket) {
    socket.close();
    socket = null;
  }
}

const getPlayerActions = () => usePlayerStore.getState().actions;

function cleanupRemoteControl() {
  const actions = getPlayerActions();
  actions.clearRemoteSender();
  actions.exitRemoteControl();
}

// LocalStorage keys
const STORAGE_KEY_IP = "lanControl.client.ip";
const STORAGE_KEY_PORT = "lanControl.client.port";
const STORAGE_KEY_PASSWORD = "lanControl.client.password";
const STORAGE_KEY_AUTO_CONNECT = "lanControl.client.autoConnect";

// Load saved connection info from localStorage
function loadSavedConnection() {
  try {
    const ip = localStorage.getItem(STORAGE_KEY_IP);
    const port = localStorage.getItem(STORAGE_KEY_PORT);
    const password = localStorage.getItem(STORAGE_KEY_PASSWORD);
    const autoConnect = localStorage.getItem(STORAGE_KEY_AUTO_CONNECT) === "true";
    return {
      ip: ip || "localhost",
      port: port ? parseInt(port, 10) : 5299,
      password: password || "",
      autoConnect,
    };
  } catch (error) {
    console.error("[LAN Control Client] Failed to load saved connection", error);
    return {
      ip: "localhost",
      port: 5299,
      password: "",
      autoConnect: false,
    };
  }
}

// Save connection info to localStorage
function saveConnection(ip: string, port: number, password: string) {
  try {
    localStorage.setItem(STORAGE_KEY_IP, ip);
    localStorage.setItem(STORAGE_KEY_PORT, port.toString());
    localStorage.setItem(STORAGE_KEY_PASSWORD, password);
    localStorage.setItem(STORAGE_KEY_AUTO_CONNECT, "true");
  } catch (error) {
    console.error("[LAN Control Client] Failed to save connection", error);
  }
}

// Clear saved connection
function clearSavedConnection() {
  try {
    localStorage.removeItem(STORAGE_KEY_IP);
    localStorage.removeItem(STORAGE_KEY_PORT);
    localStorage.removeItem(STORAGE_KEY_PASSWORD);
    localStorage.removeItem(STORAGE_KEY_AUTO_CONNECT);
  } catch (error) {
    console.error("[LAN Control Client] Failed to clear saved connection", error);
  }
}

const savedConnection = loadSavedConnection();

export const useLanControlClientStore =
  createWithEqualityFn<LanControlClientState>()(
    (set, get) => ({
      status: "disconnected",
      ip: savedConnection.ip,
      port: savedConnection.port,
      password: savedConnection.password,
      remoteDevice: null,
      playerState: null,
      currentSong: null,
      queue: null,
      lastMessageAt: null,
      error: undefined,
      actions: {
        setIp: (ip) => {
          set({ ip });
        },
        setPort: (port) => {
          set({ port });
        },
        setPassword: (password) => {
          set({ password: password.toUpperCase() });
        },
        clearError: () => {
          set({ error: undefined });
        },
        connect: () => {
          const { status, ip, port, password } = get();
          if (status === "connecting" || status === "authenticating") {
            return;
          }

          reconnectAbort = false;
          closeSocket();

          const serverUrl = `ws://${ip}:${port}`;

          let parsedUrl: URL;
          try {
            parsedUrl = new URL(serverUrl, window.location.href);
          } catch (error) {
            console.error("[LAN Control Client] Invalid URL", error);
            cleanupRemoteControl();
            set({
              status: "error",
              error: "Invalid server URL",
            });
            return;
          }

          set({
            status: "connecting",
            error: undefined,
            remoteDevice: null,
          });

          socket = new WebSocket(parsedUrl.toString());

          socket.addEventListener("open", () => {
            if (reconnectAbort) return;
            set({ status: "authenticating" });
            const payload: LanControlMessage = {
              type: LanControlMessageType.AUTH_REQUEST,
              data: {
                authType: "lan",
                password: password.trim().toUpperCase(),
              },
              timestamp: Date.now(),
            };
            socket?.send(JSON.stringify(payload));
          });

          socket.addEventListener("message", (event) => {
            if (reconnectAbort) return;
            const message = parseMessage(event);
            if (!message) return;

            switch (message.type) {
              case LanControlMessageType.AUTH_RESPONSE: {
                const response = (message.data ?? {}) as AuthResponseData;
                const success = Boolean(response?.success);
                if (success) {
                  const remoteDevice = response.deviceInfo ?? null;
                  // Save successful connection
                  saveConnection(get().ip, get().port, get().password);
                  set({
                    status: "connected",
                    remoteDevice,
                    error: undefined,
                    playerState: null,
                    currentSong: null,
                    queue: null,
                  });
                  const playerActions = getPlayerActions();
                  playerActions.registerRemoteSender((type, data) => {
                    get().actions.send({ type, data });
                  });
                  playerActions.enterRemoteControl(remoteDevice);
                  playerActions.setRemoteDevice(remoteDevice);
                  const requestState: LanControlMessage = {
                    type: LanControlMessageType.GET_STATE,
                    timestamp: Date.now(),
                  };
                  socket?.send(JSON.stringify(requestState));
                  const requestSong: LanControlMessage = {
                    type: LanControlMessageType.GET_CURRENT_SONG,
                    timestamp: Date.now(),
                  };
                  socket?.send(JSON.stringify(requestSong));
                  const requestQueue: LanControlMessage = {
                    type: LanControlMessageType.GET_QUEUE,
                    timestamp: Date.now(),
                  };
                  socket?.send(JSON.stringify(requestQueue));
                } else {
                  cleanupRemoteControl();
                  set({
                    status: "error",
                    error:
                      typeof response?.message === "string"
                        ? response.message
                        : "Authentication failed",
                  });
                  closeSocket();
                }
                break;
              }
              case LanControlMessageType.STATE_UPDATE: {
                const stateData = (message.data as PlayerStateData) ?? null;
                set({
                  playerState: stateData,
                  lastMessageAt: Date.now(),
                });
                getPlayerActions().setRemotePlayerState(stateData);
                break;
              }
              case LanControlMessageType.CURRENT_SONG_UPDATE: {
                const songData = (message.data as CurrentSongData) ?? null;
                set({
                  currentSong: songData,
                  lastMessageAt: Date.now(),
                });
                getPlayerActions().setRemoteCurrentSongData(songData);
                break;
              }
              case LanControlMessageType.QUEUE_UPDATE: {
                const queueData = (message.data as QueueData) ?? null;
                set({
                  queue: queueData,
                  lastMessageAt: Date.now(),
                });
                getPlayerActions().setRemoteQueueData(queueData);
                break;
              }
              case LanControlMessageType.ERROR: {
                const errorPayload = (message.data ?? {}) as {
                  message?: string;
                };
                cleanupRemoteControl();
                set({
                  status: "error",
                  error:
                    typeof errorPayload?.message === "string"
                      ? errorPayload.message
                      : "Server error",
                  remoteDevice: null,
                  playerState: null,
                  currentSong: null,
                  queue: null,
                });
                break;
              }
            }
          });

          socket.addEventListener("close", () => {
            if (reconnectAbort) return;
            cleanupRemoteControl();
            set((state) => ({
              status: state.status === "error" ? state.status : "disconnected",
              remoteDevice: null,
              playerState: null,
              currentSong: null,
              queue: null,
            }));
            socket = null;
          });

          socket.addEventListener("error", () => {
            if (reconnectAbort) return;
            cleanupRemoteControl();
            set({
              status: "error",
              error: "WebSocket error",
              remoteDevice: null,
              playerState: null,
              currentSong: null,
              queue: null,
            });
          });
        },
        disconnect: () => {
          reconnectAbort = true;
          closeSocket();
          cleanupRemoteControl();
          // Clear saved connection on manual disconnect
          clearSavedConnection();
          set({
            status: "disconnected",
            remoteDevice: null,
            playerState: null,
            currentSong: null,
            queue: null,
          });
        },
        send: ({ type, data }) => {
          if (!socket || socket.readyState !== WebSocket.OPEN) return;
          const payload: LanControlMessage = {
            type,
            data,
            timestamp: Date.now(),
          };
          socket.send(JSON.stringify(payload));
        },
      },
    }),
    shallow,
  );

// Auto-connect function to be called on app startup
export function tryAutoConnect() {
  const saved = loadSavedConnection();
  if (saved.autoConnect && saved.ip && saved.password) {
    // Delay to ensure store is initialized
    setTimeout(() => {
      const store = useLanControlClientStore.getState();
      if (store.status === "disconnected") {
        store.actions.connect();
      }
    }, 1000);
  }
}
