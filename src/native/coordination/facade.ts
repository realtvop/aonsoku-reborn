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

/// Native coordination client — adapts the native plugin to the
/// `CoordinationClient` surface (design §5.2). Envelope JSON produced by the
/// native plugin mirrors `src/coordination/types.ts` `Envelope`, so
/// `coordinationEvent` payloads are parsed back into `Envelope` and forwarded
/// through `ConnectionCallbacks` — the rest of the manager and store are
/// unaware of which transport is active.
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
    _sourceDeviceId?: DeviceId | null,
    _sessionId?: SessionId | null,
  ): void {
    this.plugin
      .sendTargetReady(transactionId, generation, snapshotRevision)
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
    switch (env.type) {
      case "welcome":
        if (env.deviceId) this.deviceId = env.deviceId;
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
        // command_ack / heartbeat / snapshot / hello / relinquish_ack /
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
} from "@aonsoku/capacitor-native/coordination";
