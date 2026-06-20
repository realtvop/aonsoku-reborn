// Coordination manager — the top-level orchestration layer (design §5.2).
// Owns the HTTP client, the coordination client (TS WebSocket on web/Electron,
// native plugin on iOS/Android — §5.2 multi-stack consistency), history
// outbox, and token/config store. Provides a single entry point for React
// components and the player store.

import {
  CoordinationHttpClient,
  buildSubsonicProof,
  type CoordinationCredentials,
  type StoredDeviceTokens,
} from "./httpClient";
import {
  CoordinationWsClient,
  type CoordinationClient,
  type ConnectionState,
  type ConnectionCallbacks,
} from "./wsClient";
import { HistoryOutbox } from "./outbox";
import {
  clearTokens as tsClearTokens,
  loadConfig as tsLoadConfig,
  loadTokens as tsLoadTokens,
  saveConfig as tsSaveConfig,
  saveTokens as tsSaveTokens,
  type CoordinationConfig,
} from "./tokenStore";
import { COORDINATION_PROTOCOL_VERSION, CoordinationCapability } from "./types";
import {
  NativeCoordinationClient,
  type CoordinationTokenStore,
  getNativeCoordinationAvailability,
  isNativeCoordinationAvailable,
  NativeCoordinationTokenStore,
} from "@/native/coordination";
import type {
  DeviceDto,
  DeviceId,
  HistoryOperationInput,
  HistoryPullResponse,
  PlaybackSnapshot,
  RemoteCommand,
  SessionGeneration,
  SnapshotRevision,
} from "./types";

/// TS (web/Electron) token/config store adapter — wraps the `tokenStore.ts`
/// functions behind the `CoordinationTokenStore` interface so the manager can
/// treat it and `NativeCoordinationTokenStore` uniformly.
const tsTokenStore: CoordinationTokenStore = {
  async loadTokens() {
    return await tsLoadTokens();
  },
  async saveTokens(tokens) {
    await tsSaveTokens(tokens);
  },
  async clearTokens() {
    tsClearTokens();
  },
  async loadConfig() {
    return await tsLoadConfig();
  },
  async saveConfig(config) {
    await tsSaveConfig(config);
  },
};

export interface CoordinationManagerCallbacks {
  onConnectionStateChange: (state: ConnectionState) => void;
  onDevicesChanged: (devices: DeviceDto[]) => void;
  onDeviceSnapshot: (
    deviceId: DeviceId,
    snapshot: PlaybackSnapshot,
    isOnline: boolean,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
  ) => void;
  onRemoteCommand: (command: RemoteCommand, sourceDeviceId: DeviceId) => void;
  onHandoffCandidate: (
    snapshot: PlaybackSnapshot,
    transactionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    sourceDeviceId?: DeviceId | null,
    sessionId?: SessionId | null,
  ) => void;
  onPrepareRelinquish: (
    transactionId: string,
    expectedSnapshotRevision: SnapshotRevision,
  ) => void;
  onHandoffCommitted: (
    snapshot: PlaybackSnapshot,
    newGeneration: SessionGeneration,
  ) => void;
  onHandoffFailed: (transactionId: string, code: string) => void;
  onError: (code: string, reason: string) => void;
}

export class CoordinationManager {
  private httpClient: CoordinationHttpClient | null = null;
  /// Unified coordination client — either `CoordinationWsClient` (web/Electron)
  /// or `NativeCoordinationClient` (iOS/Android). Design §5.2 multi-stack.
  private coordClient: CoordinationClient | null = null;
  private outbox = new HistoryOutbox();
  private tokens: StoredDeviceTokens | null = null;
  private config: CoordinationConfig | null = null;
  private deviceId: DeviceId | null = null;
  private capabilities =
    CoordinationCapability.HISTORY |
    CoordinationCapability.OBSERVE |
    CoordinationCapability.CONTROL |
    CoordinationCapability.HANDOFF;
  private outboxTimer: ReturnType<typeof setInterval> | null = null;
  private flushPromise: Promise<void> | null = null;
  /// Token/config store — native (Keychain/Keystore) when the native plugin is
  /// available, IndexedDB/localStorage otherwise. Only one is active at a time
  /// (design §6.3).
  private tokenStore: CoordinationTokenStore = tsTokenStore;

  constructor(private readonly callbacks: CoordinationManagerCallbacks) {}

  isConfigured(): boolean {
    return this.config !== null;
  }

  getDeviceId(): DeviceId | null {
    return this.deviceId;
  }

  getHistoryLimit(): number | null {
    return this.tokens?.historyLimit ?? null;
  }

  async loadState(): Promise<void> {
    // Pick the token/config store once at load time: native (Keychain/Keystore)
    // when the plugin is available, IndexedDB/localStorage otherwise. We do
    // NOT store in both — one store per runtime (design §6.3).
    if (isNativeCoordinationAvailable()) {
      const availability = getNativeCoordinationAvailability();
      if (availability.available) {
        this.tokenStore = new NativeCoordinationTokenStore(availability.plugin);
      }
    } else {
      this.tokenStore = tsTokenStore;
    }
    this.config = await this.tokenStore.loadConfig();
    this.tokens = await this.tokenStore.loadTokens();
    if (this.config && this.tokens) {
      this.httpClient = new CoordinationHttpClient(
        this.config.serverUrl,
        fetch.bind(globalThis),
        async (tokens) => {
          this.tokens = tokens;
          await this.tokenStore.saveTokens(tokens);
        },
      );
      this.httpClient.setTokens(this.tokens);
      this.deviceId = this.tokens.deviceId;
    }
  }

  async reconnect(): Promise<void> {
    if (!this.config || !this.tokens) return;
    if (this.coordClient) return; // Already connected or connecting

    await this.openWebSocket();
    this.startOutboxProcessor();
  }

  async saveConfig(config: CoordinationConfig): Promise<void> {
    this.config = config;
    await this.tokenStore.saveConfig(config);
  }

  async connect(
    creds: CoordinationCredentials,
    deviceName: string,
    platform: string,
    clientVersion: string,
  ): Promise<void> {
    if (!this.config)
      throw new Error("coordination: server URL not configured");
    this.httpClient = new CoordinationHttpClient(
      this.config.serverUrl,
      fetch.bind(globalThis),
      async (tokens) => {
        this.tokens = tokens;
        await this.tokenStore.saveTokens(tokens);
      },
    );

    // 1. Request a one-time challenge.
    const challenge = await this.httpClient.requestChallenge({
      identityUrl: this.config.identityUrl,
      username: creds.username,
    });

    // 2. Build the Subsonic proof from current credentials.
    const proof = buildSubsonicProof(creds);

    // 3. Register the device.
    const reg = await this.httpClient.register({
      challengeId: challenge.challengeId,
      identityUrl: this.config.identityUrl,
      username: creds.username,
      authMode: proof.authMode,
      token: proof.token,
      salt: proof.salt,
      password: proof.password,
      deviceName,
      platform,
      clientVersion,
      capabilities: this.capabilities,
    });
    this.deviceId = reg.deviceId;
    this.tokens = {
      deviceId: reg.deviceId,
      accountId: reg.accountId,
      accessToken: reg.accessToken,
      refreshToken: reg.refreshToken,
      accessTokenExpiresAt: Date.now() + reg.expiresIn * 1000,
      historyLimit: reg.historyLimit,
    };
    await this.tokenStore.saveTokens(this.tokens);

    // 4. Open the WebSocket.
    await this.openWebSocket();
    this.startOutboxProcessor();
  }

  private async openWebSocket(): Promise<void> {
    if (!this.httpClient || !this.deviceId) return;
    const wsUrl =
      this.config!.serverUrl.replace(/^http/, "ws") + "/v1/realtime";
    const cb: ConnectionCallbacks = {
      onStateChange: (s) => this.callbacks.onConnectionStateChange(s),
      onWelcome: (deviceId) => {
        this.deviceId = deviceId;
      },
      onDevicesChanged: (devices) => {
        this.callbacks.onDevicesChanged(devices);
      },
      onSnapshotProjection: (env) => {
        if (env.type === "snapshot_projection") {
          this.callbacks.onDeviceSnapshot(
            env.deviceId,
            env.snapshot,
            env.isOnline,
            env.generation,
            env.snapshotRevision,
          );
        }
      },
      onCommand: (env) => {
        if (env.type === "command") {
          this.callbacks.onRemoteCommand(env.command, env.sourceDeviceId ?? "");
        }
      },
      onHandoffCandidate: (env) => {
        if (env.type === "handoff_candidate") {
          this.callbacks.onHandoffCandidate(
            env.snapshot,
            env.transactionId,
            env.generation,
            env.snapshotRevision,
            env.sourceDeviceId,
            env.sessionId,
          );
        }
      },
      onPrepareRelinquish: (env) => {
        if (env.type === "prepare_relinquish") {
          this.callbacks.onPrepareRelinquish(
            env.transactionId,
            env.expectedSnapshotRevision,
          );
        }
      },
      onHandoffCommitted: (env) => {
        if (env.type === "handoff_committed") {
          this.callbacks.onHandoffCommitted(env.snapshot, env.newGeneration);
        }
      },
      onHandoffFailed: (env) => {
        if (env.type === "handoff_failed") {
          this.callbacks.onHandoffFailed(env.transactionId, env.code);
        }
      },
      onError: (code, reason) => this.callbacks.onError(code, reason),
    };
    const ticketFn = async (): Promise<string | null> => {
      if (!this.httpClient) return null;
      try {
        const resp = await this.httpClient.getWsTicket();
        return resp.ticket;
      } catch {
        return null;
      }
    };
    if (isNativeCoordinationAvailable()) {
      const availability = getNativeCoordinationAvailability();
      if (availability.available) {
        const nativeClient = new NativeCoordinationClient(
          availability.plugin,
          () => wsUrl,
          ticketFn,
          this.deviceId,
          this.capabilities,
          cb,
        );
        // Reconnect path: the native layer cannot self-reconnect (single-use
        // ticket, §6.3), so it fires `coordinationReconnectNeeded` and we
        // re-fetch a ticket via `openWebSocket()` (which re-ents connect()).
        // We reuse the existing `reconnect()` flow — it re-fetches a ticket
        // and calls `connect()` on the native plugin again.
        nativeClient.setReconnectHandler(async () => {
          // Drop the stale client and open a fresh connection. The old ticket
          // is single-use and expired, so we must build a new client.
          try {
            await this.coordClient?.disconnect();
          } catch {
            // ignore
          }
          this.coordClient = null;
          await this.openWebSocket();
        });
        this.coordClient = nativeClient;
        try {
          await nativeClient.connect();
          return;
        } catch {
          // Fallback to the TS client if the native plugin fails to start
          // (requirement §7 — never leave the manager with no active client).
          this.coordClient = null;
          this.callbacks.onConnectionStateChange("reconnecting");
        }
      }
    }
    // TS WebSocket path (web/Electron, or native fallback).
    this.coordClient = new CoordinationWsClient(
      () => wsUrl,
      ticketFn,
      this.deviceId,
      this.capabilities,
      cb,
    );
    await this.coordClient.connect();
  }

  private startOutboxProcessor() {
    if (this.outboxTimer) return;
    this.outboxTimer = setInterval(() => this.flushOutbox(), 10_000);
  }

  async enqueueHistoryOperation(
    operation: HistoryOperationInput,
  ): Promise<void> {
    await this.outbox.enqueue(operation);
    // Try immediate flush.
    this.flushOutbox().catch(() => {});
  }

  private async flushOutbox(): Promise<void> {
    if (this.flushPromise) return this.flushPromise;
    this.flushPromise = this.doFlushOutbox();
    try {
      await this.flushPromise;
    } finally {
      this.flushPromise = null;
    }
  }

  private async doFlushOutbox(): Promise<void> {
    if (!this.httpClient) return;
    const pending = await this.outbox.getPending();
    if (pending.length === 0) return;
    const now = Date.now();
    const due = pending.filter((e) => e.nextAttemptAt <= now);
    if (due.length === 0) return;
    try {
      const resp = await this.httpClient.pushHistory(
        due.map((e) => e.operation),
      );
      for (const result of resp.results) {
        await this.outbox.markAttempt(result.operationId, result.accepted);
      }
    } catch {
      for (const entry of due) {
        await this.outbox.markAttempt(entry.id, false);
      }
    }
  }

  async pullHistory(afterRevision: number): Promise<HistoryPullResponse> {
    if (!this.httpClient) throw new Error("coordination: not connected");
    return this.httpClient.pullHistory(afterRevision);
  }

  async legacyImport(
    entries: {
      songId: string;
      songTitle?: string;
      songArtist?: string;
      songAlbum?: string;
      songDuration?: number;
    }[],
  ): Promise<{ mergedSongIds: string[]; isFirstDevice: boolean }> {
    if (!this.httpClient) throw new Error("coordination: not connected");
    return this.httpClient.legacyImport({ entries });
  }

  async renameDevice(id: DeviceId, name: string): Promise<void> {
    if (!this.httpClient) throw new Error("coordination: not connected");
    await this.httpClient.renameDevice(id, name);
  }

  async revokeDevice(id: DeviceId): Promise<void> {
    if (!this.httpClient) throw new Error("coordination: not connected");
    await this.httpClient.revokeDevice(id);
  }

  async deleteAccount(): Promise<void> {
    if (!this.httpClient) throw new Error("coordination: not connected");
    await this.httpClient.deleteAccount();
    await this.tokenStore.clearTokens();
    await this.disconnect();
  }

  publishSnapshot(
    sessionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    snapshot: PlaybackSnapshot,
  ) {
    this.coordClient?.publishSnapshot(
      sessionId,
      generation,
      snapshotRevision,
      snapshot,
    );
  }

  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
  ) {
    this.coordClient?.sendCommand(targetDeviceId, expectedGeneration, command);
  }

  requestHandoffCandidate(
    sourceDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    expectedSnapshotRevision: SnapshotRevision,
  ) {
    this.coordClient?.requestHandoffCandidate(
      sourceDeviceId,
      expectedGeneration,
      expectedSnapshotRevision,
    );
  }

  sendTargetReady(
    transactionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    sourceDeviceId?: DeviceId | null,
    sessionId?: SessionId | null,
  ) {
    this.coordClient?.sendTargetReady(
      transactionId,
      generation,
      snapshotRevision,
      sourceDeviceId,
      sessionId,
    );
  }

  sendRelinquishAck(transactionId: string, snapshot: PlaybackSnapshot) {
    this.coordClient?.sendRelinquishAck(transactionId, snapshot);
  }

  async disconnect(): Promise<void> {
    this.coordClient?.disconnect();
    this.coordClient = null;
    if (this.outboxTimer) {
      clearInterval(this.outboxTimer);
      this.outboxTimer = null;
    }
    this.tokens = null;
    this.httpClient = null;
  }
}

export { COORDINATION_PROTOCOL_VERSION };
