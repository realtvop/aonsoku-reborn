// Native coordination facade (design §5.2).
//
// Wraps the `@aonsoku/capacitor-native/coordination` plugin so the
// `CoordinationManager` can talk to the native WebSocket layer on iOS/Android
// with the same surface area as the TypeScript `CoordinationWsClient`. On
// web/Electron the plugin is unavailable and the manager falls back to the TS
// client. Mirrors the facade pattern in `src/native/audio/facade.ts` and
// `src/native/bridge/facade.ts`.

import { Capacitor } from "@capacitor/core";
import type { PluginListenerHandle } from "@capacitor/core";
import {
  AonsokuNativeCoordination,
  COORDINATION_PLUGIN_NAME,
  type AonsokuNativeCoordinationPlugin,
} from "@aonsoku/capacitor-native/coordination";
import type {
  CoordinationClient,
  ConnectionCallbacks,
} from "@/coordination/wsClient";
import type { ConnectionState } from "@/coordination/wsClient";
import type { CoordinationConfig } from "@/coordination/tokenStore";
import type { StoredDeviceTokens } from "@/coordination/httpClient";
import type {
  DeviceId,
  Envelope,
  MessageId,
  PlaybackSnapshot,
  RemoteCommand,
  SessionGeneration,
  SessionId,
  SnapshotRevision,
} from "@/coordination/types";
import {
  COORDINATION_PROTOCOL_VERSION,
  CoordinationCapability,
} from "@/coordination/types";
import type { CommandResult, ConnectionSeq } from "@/coordination/types";
import type {
  SendCommandOptions,
  RefreshGenerationFn,
} from "@/coordination/wsClient";

export type NativeCoordinationAvailability =
  | { available: true; plugin: AonsokuNativeCoordinationPlugin }
  | { available: false; reason: string };

const NATIVE_COORDINATION_PLATFORMS = ["ios", "android"];

/// Returns whether the native coordination plugin is available. Mirrors
/// `getNativeAudioPluginAvailability()` — true only when running on a native
/// Capacitor platform (iOS/Android) **and** the plugin is actually registered.
export function getNativeCoordinationAvailability(): NativeCoordinationAvailability {
  if (
    !Capacitor.isNativePlatform() ||
    !NATIVE_COORDINATION_PLATFORMS.includes(Capacitor.getPlatform())
  ) {
    return {
      available: false,
      reason: "Only supported on native Capacitor platforms (iOS/Android)",
    };
  }

  if (!Capacitor.isPluginAvailable(COORDINATION_PLUGIN_NAME)) {
    return {
      available: false,
      reason: "Native coordination plugin is not installed",
    };
  }

  return { available: true, plugin: AonsokuNativeCoordination };
}

export function isNativeCoordinationAvailable(): boolean {
  return getNativeCoordinationAvailability().available;
}

/// Token/config store backed by the native plugin (Keychain/Keystore +
/// preferences). Implements the same interface as the TS
/// `tokenStore.ts` functions so the manager can swap in the native-backed
/// store when the plugin is available (design §6.3). Only one store is active
/// at a time — the manager picks native or IndexedDB/localStorage, never both.
export class NativeCoordinationTokenStore {
  constructor(private readonly plugin: AonsokuNativeCoordinationPlugin) {}

  async loadTokens(): Promise<StoredDeviceTokens | null> {
    const stored = await this.plugin.loadTokens();
    if (!stored) return null;
    // The native plugin persists the access/refresh token + deviceId +
    // accountId + historyLimit. The access token expiry is recomputed from
    // the server response at connect time; if the plugin has no expiry
    // metadata we treat the stored access token as already-expired so the
    // HTTP client refreshes on next use.
    return {
      deviceId: stored.deviceId,
      accountId: stored.accountId,
      accessToken: stored.accessToken,
      refreshToken: stored.refreshToken,
      accessTokenExpiresAt: 0,
      historyLimit: stored.historyLimit,
    };
  }

  async saveTokens(tokens: StoredDeviceTokens | null): Promise<void> {
    if (!tokens) {
      await this.plugin.clearTokens();
      return;
    }
    await this.plugin.storeTokens({
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      deviceId: tokens.deviceId,
      accountId: tokens.accountId,
      historyLimit: tokens.historyLimit,
    });
  }

  async clearTokens(): Promise<void> {
    await this.plugin.clearTokens();
  }

  async loadConfig(): Promise<CoordinationConfig | null> {
    const cfg = await this.plugin.loadConfig();
    if (!cfg) return null;
    return { serverUrl: cfg.serverUrl, identityUrl: cfg.identityUrl };
  }

  async saveConfig(config: CoordinationConfig | null): Promise<void> {
    if (!config) {
      // The native plugin has no explicit clear-config; overwrite with empty.
      await this.plugin.storeConfig({ serverUrl: "", identityUrl: "" });
      return;
    }
    await this.plugin.storeConfig({
      serverUrl: config.serverUrl,
      identityUrl: config.identityUrl,
    });
  }
}

/// Interface for token/config persistence used by `CoordinationManager`. Both
/// the TS `tokenStore.ts` function set and `NativeCoordinationTokenStore`
/// satisfy it, so the manager can hold a single reference regardless of
/// transport.
export interface CoordinationTokenStore {
  loadTokens(): Promise<StoredDeviceTokens | null>;
  saveTokens(tokens: StoredDeviceTokens | null): Promise<void>;
  clearTokens(): Promise<void>;
  loadConfig(): Promise<CoordinationConfig | null>;
  saveConfig(config: CoordinationConfig | null): Promise<void>;
}

/// §9.1 dedup cache for incoming envelopes. Mirrors the TS client's cache:
/// the server replays the original result for a replayed messageId, so a
/// duplicate here is expected and is skipped silently.
class DedupCache {
  private readonly seen = new Map<MessageId, number>();
  private readonly max: number;
  constructor(max = 200) {
    this.max = max;
  }
  has(id: MessageId): boolean {
    return this.seen.has(id);
  }
  mark(id: MessageId): void {
    if (this.seen.has(id)) return;
    if (this.seen.size >= this.max) {
      const oldest = this.seen.keys().next().value;
      if (oldest !== undefined) this.seen.delete(oldest);
    }
    this.seen.set(id, Date.now());
  }
  clear(): void {
    this.seen.clear();
  }
  size(): number {
    return this.seen.size;
  }
}

/// §9.1 pending-ack entry. Holds the caller's resolve/reject and a timeout
/// timer so the facade can resolve the `sendCommandAck()` promise when the
/// native plugin emits `coordinationAck`.
interface PendingAck {
  messageId: MessageId;
  createdAt: number;
  resolve: (result: CommandResult) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  retry: {
    targetDeviceId: DeviceId;
    expectedGeneration: SessionGeneration;
    command: RemoteCommand;
    options: SendCommandOptions;
    attempted: boolean;
  };
}

const DEFAULT_ACK_TIMEOUT_MS = 10_000;

/// Native coordination client — adapts the native plugin to the
/// `CoordinationClient` surface (design §5.2). Envelope JSON produced by the
/// native plugin mirrors `src/coordination/types.ts` `Envelope`, so
/// `coordinationEvent` payloads are parsed back into `Envelope` and forwarded
/// through `ConnectionCallbacks` — the rest of the manager and store are
/// unaware of which transport is active.
///
/// §9.1 ack/seq/dedup: the facade tracks `lastSeq` on every incoming envelope
/// and submits it in the next `connect()` call's `lastSeq` option. It
/// maintains a dedup cache for incoming `command`/`snapshot_projection`
/// envelopes and a pending-ack map so `sendCommandAck()` can return a
/// `Promise<CommandResult>`. The native plugin emits `coordinationAck` when
/// a `command_ack` envelope arrives; the facade resolves the matching
/// pending entry.
///
/// Reconnect: the native plugin fires `coordinationReconnectNeeded` after an
/// unexpected disconnect (the WebSocket ticket is one-time/expiring so the
/// native layer cannot self-reconnect). The manager registers a reconnect
/// callback via `setReconnectHandler` which re-fetches a ticket via
/// `httpClient.getWsTicket()` and calls `connect()` again.
export class NativeCoordinationClient implements CoordinationClient {
  private state: ConnectionState = "disconnected";
  private deviceId: DeviceId | null;
  private capabilities: number;
  private reconnectHandler: (() => Promise<void>) | null = null;
  private listeners: PluginListenerHandle[] = [];
  private disposed = false;
  /// §9.2: highest server seq the client has processed. Submitted in the
  /// next `connect()` call's `lastSeq` option.
  private lastSeq: ConnectionSeq = 0;
  /// §9.1 dedup cache for incoming envelopes.
  private dedup = new DedupCache();
  /// §9.1 pending-ack map keyed by messageId.
  private pendingAcks = new Map<MessageId, PendingAck>();
  /// §13 stale-epoch retry hook. Wired by the manager.
  private refreshGenerationFn: RefreshGenerationFn | null = null;

  constructor(
    private readonly plugin: AonsokuNativeCoordinationPlugin,
    private readonly urlFn: () => string,
    private readonly ticketFn: () => Promise<string | null>,
    deviceId: DeviceId | null,
    capabilities: number,
    private readonly callbacks: ConnectionCallbacks,
  ) {
    this.deviceId = deviceId;
    this.capabilities = capabilities;
  }

  /// Register a reconnect handler invoked when the native plugin requests a
  /// fresh ticket (design §6.3, §9 reconnect). The manager re-fetches a ticket
  /// and calls `connect()` again.
  setReconnectHandler(handler: () => Promise<void>): void {
    this.reconnectHandler = handler;
  }

  /// §13: wire the stale-epoch retry hook. The manager passes a function
  /// that resolves to the latest generation for a target device.
  setRefreshGenerationFn(fn: RefreshGenerationFn): void {
    this.refreshGenerationFn = fn;
  }

  /// Test-only: inspect the dedup cache size.
  internalDedupSize(): number {
    return this.dedup.size();
  }

  /// Test-only: inspect the pending-ack map size.
  internalPendingAckSize(): number {
    return this.pendingAcks.size;
  }

  /// Test-only: current tracked lastSeq.
  internalLastSeq(): ConnectionSeq {
    return this.lastSeq;
  }

  getState(): ConnectionState {
    return this.state;
  }

  async connect(): Promise<void> {
    if (this.disposed) return;
    if (this.state === "connecting" || this.state === "connected") return;
    this.setState("connecting");

    const ticket = await this.ticketFn();
    if (!ticket) {
      this.setState("error");
      this.callbacks.onError("authentication_failed", "no ws ticket available");
      return;
    }

    await this.attachListeners();

    try {
      await this.plugin.connect({
        wsUrl: this.urlFn(),
        ticket,
        deviceId: this.deviceId ?? "",
        capabilities: this.capabilities,
        protocolVersion: COORDINATION_PROTOCOL_VERSION,
        lastSeq: this.lastSeq,
      });
    } catch (err) {
      this.setState("error");
      this.callbacks.onError(
        "internal",
        err instanceof Error ? err.message : "native connect failed",
      );
    }
  }

  disconnect(): void {
    this.disposed = true;
    for (const handle of this.listeners) {
      handle.remove().catch(() => {});
    }
    this.listeners = [];
    // Reject in-flight acks so callers don't hang on teardown.
    for (const pending of this.pendingAcks.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("coordination: disconnected before ack"));
    }
    this.pendingAcks.clear();
    // The dedup cache is per-connection; clear it so a reconnect does not
    // falsely skip messages from the new connection.
    this.dedup.clear();
    this.plugin.disconnect().catch(() => {});
    this.setState("disconnected");
  }

  publishSnapshot(
    sessionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    snapshot: PlaybackSnapshot,
  ): void {
    this.plugin
      .publishSnapshot({
        sessionId,
        generation,
        snapshotRevision,
        snapshotJson: JSON.stringify(snapshot),
      })
      .catch(() => {});
  }

  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
  ): void {
    this.plugin
      .sendCommand({
        targetDeviceId,
        expectedGeneration,
        commandJson: JSON.stringify(command),
      })
      .catch(() => {});
  }

  /// §9.1 ack overload: sends the command and resolves with the
  /// `CommandResult` when the native plugin emits `coordinationAck` for
  /// the matching messageId. Rejects after the timeout. Supports a single
  /// stale-epoch retry when `options.retryOnStaleEpoch` is true.
  sendCommandAck(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
    options: SendCommandOptions,
  ): Promise<CommandResult> {
    const messageId = crypto.randomUUID();
    const retry: PendingAck["retry"] = {
      targetDeviceId,
      expectedGeneration,
      command,
      options,
      attempted: false,
    };
    const promise = this.trackPendingAck(messageId, retry, options);
    this.plugin
      .sendCommand({
        targetDeviceId,
        expectedGeneration,
        commandJson: JSON.stringify(command),
        messageId,
      })
      .catch((err) => {
        const pending = this.pendingAcks.get(messageId);
        if (pending) {
          clearTimeout(pending.timer);
          this.pendingAcks.delete(messageId);
          pending.reject(
            err instanceof Error ? err : new Error("native sendCommand failed"),
          );
        }
      });
    return promise;
  }

  /// Register a pending-ack entry with a timeout timer.
  private trackPendingAck(
    messageId: MessageId,
    retry: PendingAck["retry"],
    options: SendCommandOptions,
  ): Promise<CommandResult> {
    return new Promise<CommandResult>((resolve, reject) => {
      const timeoutMs = options.timeoutMs ?? DEFAULT_ACK_TIMEOUT_MS;
      const timer = setTimeout(() => {
        this.pendingAcks.delete(messageId);
        reject(new Error(`command_ack timeout after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pendingAcks.set(messageId, {
        messageId,
        createdAt: Date.now(),
        resolve,
        reject,
        timer,
        retry,
      });
    });
  }

  /// Resend a command with an updated expectedGeneration (stale-epoch
  /// retry, §13). Reuses the original `PendingAck`'s resolve/reject so the
  /// caller's promise resolves/rejects with the retry result. A new
  /// messageId is generated and a fresh timeout timer is armed.
  private resendCommand(
    pending: PendingAck,
    newGeneration: SessionGeneration,
  ): void {
    const messageId = crypto.randomUUID();
    const timeoutMs = pending.retry.options.timeoutMs ?? DEFAULT_ACK_TIMEOUT_MS;
    pending.timer = setTimeout(() => {
      this.pendingAcks.delete(messageId);
      pending.reject(new Error(`command_ack timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    this.pendingAcks.set(messageId, pending);
    this.plugin
      .sendCommand({
        targetDeviceId: pending.retry.targetDeviceId,
        expectedGeneration: newGeneration,
        commandJson: JSON.stringify(pending.retry.command),
        messageId,
      })
      .catch(() => {});
  }

  requestHandoffCandidate(
    sourceDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    expectedSnapshotRevision: SnapshotRevision,
  ): void {
    this.plugin
      .requestHandoffCandidate(
        sourceDeviceId,
        expectedGeneration,
        expectedSnapshotRevision,
      )
      .catch(() => {});
  }

  sendTargetReady(
    transactionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    sourceDeviceId?: DeviceId | null,
    sessionId?: SessionId | null,
  ): void {
    if (!sourceDeviceId || !sessionId) return;
    this.plugin
      .sendTargetReady(
        transactionId,
        generation,
        snapshotRevision,
        sourceDeviceId,
        sessionId,
      )
      .catch(() => {});
  }

  sendRelinquishAck(transactionId: string, snapshot: PlaybackSnapshot): void {
    this.plugin
      .sendRelinquishAck({
        transactionId,
        snapshotJson: JSON.stringify(snapshot),
      })
      .catch(() => {});
  }

  requestSnapshots(): void {
    this.plugin.requestSnapshots().catch(() => {});
  }

  private async attachListeners(): Promise<void> {
    if (this.listeners.length > 0) return;
    // `coordinationEvent` — incoming envelope JSON.
    const eventHandle = await this.plugin.addListener(
      "coordinationEvent",
      (data: { envelopeJson: string }) => {
        try {
          const env = JSON.parse(data.envelopeJson) as Envelope;
          this.handleEnvelope(env);
        } catch {
          // Malformed message; ignore (mirrors wsClient behavior).
        }
      },
    );
    this.listeners.push(eventHandle);

    // §9.1 `coordinationAck` — emitted by the native plugin when a
    // `command_ack` envelope arrives, so the facade can resolve the
    // pending `sendCommandAck()` promise. The native plugin also tracks
    // lastSeq/dedup on its side; this event is the bridge back to the
    // WebView-side promise.
    const ackHandle = await this.plugin.addListener(
      "coordinationAck",
      (data: { messageId: string; resultJson: string }) => {
        const pending = this.pendingAcks.get(data.messageId);
        if (!pending) return;
        let result: CommandResult;
        try {
          result = JSON.parse(data.resultJson) as CommandResult;
        } catch {
          // Malformed ack payload — reject the pending promise so the
          // caller does not hang.
          clearTimeout(pending.timer);
          this.pendingAcks.delete(data.messageId);
          pending.reject(new Error("coordination: malformed ack result"));
          return;
        }
        // §13 stale-epoch retry path.
        if (
          result.status === "error" &&
          result.code === "stale_epoch" &&
          pending.retry.options.retryOnStaleEpoch &&
          !pending.retry.attempted &&
          this.refreshGenerationFn
        ) {
          clearTimeout(pending.timer);
          this.pendingAcks.delete(data.messageId);
          pending.retry.attempted = true;
          this.refreshGenerationFn(pending.retry.targetDeviceId)
            .then((gen) => {
              if (gen === null) {
                pending.reject(
                  new Error("stale_epoch retry: could not refresh generation"),
                );
                return;
              }
              this.resendCommand(pending, gen);
            })
            .catch((err) => pending.reject(err));
          return;
        }
        // §13: a second stale_epoch after a retry was attempted rejects.
        if (
          result.status === "error" &&
          result.code === "stale_epoch" &&
          pending.retry.attempted
        ) {
          clearTimeout(pending.timer);
          this.pendingAcks.delete(data.messageId);
          pending.reject(
            new Error("stale_epoch: generation still stale after retry"),
          );
          return;
        }
        clearTimeout(pending.timer);
        this.pendingAcks.delete(data.messageId);
        pending.resolve(result);
      },
    );
    this.listeners.push(ackHandle);

    // `coordinationStateChange` — connection state updates from the native
    // layer. Forwarded through the same `ConnectionCallbacks`.
    const stateHandle = await this.plugin.addListener(
      "coordinationStateChange",
      (data: { state: ConnectionState; deviceId: string | null }) => {
        this.deviceId = data.deviceId ?? this.deviceId;
        this.setState(data.state);
      },
    );
    this.listeners.push(stateHandle);

    // `coordinationReconnectNeeded` — the native layer cannot self-reconnect
    // (single-use ticket), so it asks the WebView to fetch a fresh ticket and
    // call `connect()` again (§6.3).
    const reconnectHandle = await this.plugin.addListener(
      "coordinationReconnectNeeded",
      (_data: { attempt: number }) => {
        this.setState("reconnecting");
        if (this.reconnectHandler) {
          this.reconnectHandler().catch(() => {});
        }
      },
    );
    this.listeners.push(reconnectHandle);
  }

  private handleEnvelope(env: Envelope): void {
    // §9.2: track the incoming seq on every envelope so the next `connect()`
    // can submit `lastSeq` and the server can skip already-delivered messages.
    if (typeof env.seq === "number" && env.seq > this.lastSeq) {
      this.lastSeq = env.seq;
    }

    // §9.1: dedup incoming command/snapshot envelopes by messageId.
    if (
      (env.type === "command" || env.type === "snapshot_projection") &&
      env.messageId
    ) {
      if (this.dedup.has(env.messageId)) {
        return;
      }
      this.dedup.mark(env.messageId);
    }

    switch (env.type) {
      case "welcome":
        if (env.deviceId) this.deviceId = env.deviceId;
        if (typeof env.seq === "number" && env.seq > this.lastSeq) {
          this.lastSeq = env.seq;
        }
        this.callbacks.onWelcome(
          env.deviceId,
          env.connectionId ?? "",
          env.negotiated ?? CoordinationCapability.NONE,
        );
        break;
      case "heartbeat_ack":
        // No action needed (mirrors wsClient).
        break;
      case "devices_changed":
        this.callbacks.onDevicesChanged(env.devices);
        break;
      case "snapshot_projection":
        this.callbacks.onSnapshotProjection(env);
        break;
      case "command":
        this.callbacks.onCommand(env);
        break;
      case "command_ack":
        // The native plugin emits `coordinationAck` separately; the envelope
        // is handled by the ack listener, not here.
        break;
      case "handoff_candidate":
        this.callbacks.onHandoffCandidate(env);
        break;
      case "prepare_relinquish":
        this.callbacks.onPrepareRelinquish(env);
        break;
      case "handoff_committed":
        this.callbacks.onHandoffCommitted(env);
        break;
      case "handoff_failed":
        this.callbacks.onHandoffFailed(env);
        break;
      case "session_superseded":
        this.callbacks.onSessionSuperseded(env);
        break;
      case "error":
        this.callbacks.onError(env.code, env.reason);
        break;
      case "capability_disabled":
        this.callbacks.onError(
          "protocol_incompatible",
          `feature disabled: ${env.feature}`,
        );
        break;
      default:
        // heartbeat / snapshot / hello / relinquish_ack /
        // handoff_candidate_request / target_ready — outbound or ignored.
        break;
    }
  }

  private setState(state: ConnectionState): void {
    if (this.state === state) return;
    this.state = state;
    this.callbacks.onStateChange(state);
  }
}

export {
  AonsokuNativeCoordination,
  COORDINATION_PLUGIN_NAME,
} from "@aonsoku/capacitor-native/coordination";
export type {
  AonsokuNativeCoordinationPlugin,
  CoordinationConnectOptions,
  CoordinationStateResult,
  CoordinationSnapshotOptions,
  CoordinationCommandOptions,
  CoordinationHandoffOptions,
  CoordinationTokenOptions,
  CoordinationConfigOptions,
  CoordinationAckEvent,
} from "@aonsoku/capacitor-native/coordination";
