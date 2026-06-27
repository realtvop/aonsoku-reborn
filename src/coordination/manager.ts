// Coordination manager — the top-level orchestration layer (design §5.2).
// Owns the HTTP client, the coordination client (TS WebSocket on web/Electron,
// native plugin on iOS/Android — §5.2 multi-stack consistency), history
// outbox, and token/config store. Provides a single entry point for React
// components and the player store.

import {
  type CoordinationTokenStore,
  createNativeCoordinationFetch,
  getNativeCoordinationAvailability,
  isNativeCoordinationAvailable,
  NativeCoordinationClient,
  NativeCoordinationTokenStore,
} from "@/native/coordination";
import {
  buildSubsonicProof,
  type CoordinationCredentials,
  CoordinationHttpClient,
  type CoordinationRecoveryProvider,
  type StoredDeviceTokens,
} from "./httpClient";
import { HistoryOutbox } from "./outbox";
import {
  type CoordinationConfig,
  clearTokens as tsClearTokens,
  loadConfig as tsLoadConfig,
  loadTokens as tsLoadTokens,
  saveConfig as tsSaveConfig,
  saveTokens as tsSaveTokens,
} from "./tokenStore";
import type {
  CommandResult,
  DeviceDto,
  DeviceId,
  HistoryOperationInput,
  HistoryPullResponse,
  PlaybackSnapshot,
  RemoteCommand,
  SessionGeneration,
  SnapshotRevision,
} from "./types";
import { COORDINATION_PROTOCOL_VERSION, CoordinationCapability } from "./types";
import {
  type ConnectionCallbacks,
  type ConnectionState,
  type CoordinationClient,
  CoordinationWsClient,
  type SendCommandOptions,
} from "./wsClient";

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
    serverTime: number,
    lastConfirmedAt: number,
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
  onSessionSuperseded: (
    supersededGeneration: SessionGeneration,
    transferredToDevice: DeviceId | null,
    sessionId?: SessionId | null,
  ) => void;
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
  /// Per-device latest generation cache, fed by `onDeviceSnapshot`. Used
  /// by the stale-epoch retry path to refresh `expectedGeneration` without
  /// a round-trip to the server when a recent snapshot is available.
  private deviceGenerations = new Map<DeviceId, SessionGeneration>();
  /// Per-device latest snapshot-revision cache, fed by `onDeviceSnapshot`.
  /// Used by the source_changed retry path (design §11.2) to refresh
  /// `expectedSnapshotRevision` before resending `handoff_candidate_request`.
  private deviceSnapshotRevisions = new Map<DeviceId, SnapshotRevision>();
  /// Pending resolvers waiting for the next `snapshot_projection` for a
  /// given device (source_changed retry path).
  private deviceSnapshotWaiters = new Map<
    DeviceId,
    Array<(gen: SessionGeneration, rev: SnapshotRevision) => void>
  >();
  /// Token/config store — native (Keychain/Keystore) when the native plugin is
  /// available, IndexedDB/localStorage otherwise. Only one is active at a time
  /// (design §6.3).
  private tokenStore: CoordinationTokenStore = tsTokenStore;
  private fetchImpl: typeof fetch = fetch.bind(globalThis);

  constructor(
    private readonly callbacks: CoordinationManagerCallbacks,
    private readonly getRecoveryCredentials?: CoordinationRecoveryProvider,
  ) {}

  isConfigured(): boolean {
    return this.config !== null;
  }

  getConfig(): CoordinationConfig | null {
    return this.config;
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
        this.fetchImpl = createNativeCoordinationFetch(availability.plugin);
      }
    } else {
      this.tokenStore = tsTokenStore;
      this.fetchImpl = fetch.bind(globalThis);
    }
    this.config = await this.tokenStore.loadConfig();
    this.tokens = await this.tokenStore.loadTokens();
    if (this.config && this.tokens) {
      this.httpClient = new CoordinationHttpClient(
        this.config.serverUrl,
        this.fetchImpl,
        async (tokens) => {
          this.tokens = tokens;
          await this.tokenStore.saveTokens(tokens);
        },
        this.getRecoveryCredentials,
      );
      this.httpClient.setTokens(this.tokens);
      this.deviceId = this.tokens.deviceId;
    }
  }

  async reconnect(): Promise<void> {
    if (!this.config || !this.tokens) return;
    if (this.coordClient) {
      const state = this.coordClient.getState();
      if (
        state === "connected" ||
        state === "connecting" ||
        state === "reconnecting"
      ) {
        return;
      }

      this.coordClient.disconnect();
      this.coordClient = null;
    }

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
      this.fetchImpl,
      async (tokens) => {
        this.tokens = tokens;
        await this.tokenStore.saveTokens(tokens);
      },
      this.getRecoveryCredentials,
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
        this.refreshDevices().catch(() => {});
        // Bootstrap: fetch current online peer snapshots so the cross-device
        // panel shows A's live playback as soon as B connects, without
        // waiting for A's next periodic publish (design §9.2).
        this.coordClient?.requestSnapshots?.();
      },
      onDevicesChanged: (devices) => {
        this.callbacks.onDevicesChanged(devices);
      },
      onSnapshotProjection: (env) => {
        if (env.type === "snapshot_projection") {
          // Feed the generation cache so the stale-epoch retry path can
          // refresh without a server round-trip.
          this.deviceGenerations.set(env.deviceId, env.generation);
          this.deviceSnapshotRevisions.set(env.deviceId, env.snapshotRevision);
          // Notify any source_changed retry waiters for this device.
          const waiters = this.deviceSnapshotWaiters.get(env.deviceId);
          if (waiters && waiters.length > 0) {
            this.deviceSnapshotWaiters.delete(env.deviceId);
            for (const resolve of waiters) {
              resolve(env.generation, env.snapshotRevision);
            }
          }
          this.callbacks.onDeviceSnapshot(
            env.deviceId,
            env.snapshot,
            env.isOnline,
            env.generation,
            env.snapshotRevision,
            env.serverTime ?? env.lastConfirmedAt,
            env.lastConfirmedAt,
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
      onSessionSuperseded: (env) => {
        if (env.type === "session_superseded") {
          // Invalidate the generation cache for this session's owning device
          // so future retries don't reuse the stale generation.
          this.deviceGenerations.delete(this.deviceId ?? "");
          this.deviceSnapshotRevisions.delete(this.deviceId ?? "");
          this.callbacks.onSessionSuperseded(
            env.supersededGeneration,
            env.transferredToDevice ?? null,
            env.sessionId,
          );
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
        this.wireRefreshGeneration(nativeClient);
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
    const tsClient = new CoordinationWsClient(
      () => wsUrl,
      ticketFn,
      this.deviceId,
      this.capabilities,
      cb,
    );
    this.coordClient = tsClient;
    this.wireRefreshGeneration(tsClient);
    await this.coordClient.connect();
  }

  /// Wire the stale-epoch retry hook (design §13). The refresh function
  /// returns the latest known generation for a target device from the
  /// `onDeviceSnapshot` cache, or null if unknown so the caller's promise
  /// rejects with a clear reason.
  private wireRefreshGeneration(
    client: CoordinationClient & {
      setRefreshGenerationFn?: (
        fn: (deviceId: DeviceId) => Promise<SessionGeneration | null>,
      ) => void;
    },
  ): void {
    if (typeof client.setRefreshGenerationFn === "function") {
      client.setRefreshGenerationFn(async (targetDeviceId) => {
        const cached = this.deviceGenerations.get(targetDeviceId);
        if (cached !== undefined) return cached;
        // Fall back to a fresh device list when we have no cached snapshot.
        // DeviceDto does not carry a generation, so the HTTP fallback
        // cannot refresh the generation — signal failure so the caller's
        // promise rejects with a clear reason instead of silently
        // retrying with a stale value.
        if (!this.httpClient) return null;
        try {
          await this.httpClient.listDevices();
          return null;
        } catch {
          return null;
        }
      });
    }
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
    await this.refreshDevices();
  }

  async revokeDevice(id: DeviceId): Promise<void> {
    if (!this.httpClient) throw new Error("coordination: not connected");
    await this.httpClient.revokeDevice(id);
    await this.refreshDevices();
  }

  async forgetCurrentDevice(): Promise<void> {
    await this.tokenStore.clearTokens();
    await this.disconnect();
  }

  async deleteAccount(): Promise<void> {
    if (!this.httpClient) throw new Error("coordination: not connected");
    await this.httpClient.deleteAccount();
    await this.forgetCurrentDevice();
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
  ): void;
  /// §9.1 ack overload: resolves with the `CommandResult` returned by the
  /// server, or rejects after the timeout. Pass `retryOnStaleEpoch: true`
  /// to opt into a single stale-epoch retry that refreshes the generation
  /// from the device-snapshot cache and resends.
  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
    options: SendCommandOptions,
  ): Promise<CommandResult>;
  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
    options?: SendCommandOptions,
  ): void | Promise<CommandResult> {
    if (options?.awaitAck && this.coordClient?.sendCommandAck) {
      return this.coordClient.sendCommandAck(
        targetDeviceId,
        expectedGeneration,
        command,
        options,
      );
    }
    this.coordClient?.sendCommand(targetDeviceId, expectedGeneration, command);
    return;
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

  sendActiveControlCommand(command: RemoteCommand): void {
    this.coordClient?.sendActiveControlCommand?.(command);
  }

  /// Request a fresh snapshot broadcast from the server (§9.2 bootstrap
  /// path). Used by the receiver to re-sync playback progress when its tab
  /// returns to the foreground after being throttled in the background.
  requestSnapshots(): void {
    this.coordClient?.requestSnapshots?.();
  }

  private async refreshDevices(): Promise<void> {
    if (!this.httpClient) return;
    try {
      const devices = await this.httpClient.listDevices();
      this.callbacks.onDevicesChanged(devices);
    } catch (err) {
      this.callbacks.onError(
        "devices_refresh_failed",
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  /// Returns the latest cached `generation` / `snapshotRevision` for a device,
  /// or `null` if unknown. Fed by `onDeviceSnapshot` projections (design §9.2).
  /// Used by the source_changed retry path (§11.2) to refresh the handoff
  /// candidate request before resending.
  getLatestDeviceSnapshot(deviceId: DeviceId): {
    generation: SessionGeneration;
    snapshotRevision: SnapshotRevision;
  } | null {
    const generation = this.deviceGenerations.get(deviceId);
    const snapshotRevision = this.deviceSnapshotRevisions.get(deviceId);
    if (generation === undefined || snapshotRevision === undefined) return null;
    return { generation, snapshotRevision };
  }

  /// Resolves with the next `snapshot_projection` arrival for `deviceId`,
  /// carrying the fresh `generation` / `snapshotRevision`. Rejects after
  /// `timeoutMs` (default 8s) if no projection arrives. Used by the
  /// source_changed retry path (design §11.2) to wait for the source device's
  /// newest snapshot before resending `handoff_candidate_request`.
  waitForDeviceSnapshotUpdate(
    deviceId: DeviceId,
    timeoutMs = 8000,
  ): Promise<{
    generation: SessionGeneration;
    snapshotRevision: SnapshotRevision;
  }> {
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        const arr = this.deviceSnapshotWaiters.get(deviceId);
        if (arr) {
          const idx = arr.indexOf(resolveFn);
          if (idx >= 0) arr.splice(idx, 1);
          if (arr.length === 0) this.deviceSnapshotWaiters.delete(deviceId);
        }
        reject(
          new Error(
            "source_changed retry: timed out waiting for snapshot update",
          ),
        );
      }, timeoutMs);
      const resolveFn = (gen: SessionGeneration, rev: SnapshotRevision) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve({ generation: gen, snapshotRevision: rev });
      };
      const arr = this.deviceSnapshotWaiters.get(deviceId) ?? [];
      arr.push(resolveFn);
      this.deviceSnapshotWaiters.set(deviceId, arr);
    });
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

  /// §10 exclusivity: notify the server that this device is starting remote
  /// control of `targetDeviceId`. Other devices will be forbidden from
  /// remote-controlling or handoff-taking this device while active.
  sendControlSessionBegin(targetDeviceId: DeviceId): void {
    this.coordClient?.sendControlSessionBegin(targetDeviceId);
  }

  /// §10 exclusivity: notify the server that this device has stopped remote
  /// control.
  sendControlSessionEnd(): void {
    this.coordClient?.sendControlSessionEnd();
  }

  async disconnect(): Promise<void> {
    this.coordClient?.disconnect();
    this.coordClient = null;
    if (this.outboxTimer) {
      clearInterval(this.outboxTimer);
      this.outboxTimer = null;
    }
    this.deviceGenerations.clear();
    this.deviceSnapshotRevisions.clear();
    this.deviceSnapshotWaiters.clear();
    this.tokens = null;
    this.httpClient = null;
  }
}

export { COORDINATION_PROTOCOL_VERSION };
